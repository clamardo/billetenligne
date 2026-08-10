import 'dart:convert';
import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:crypto/crypto.dart';

import '../application/ports/notification_gateway.dart';

/// Azure Communication Services, for both SMS and transactional email
/// (ADR-0019).
///
/// Configured exactly as CogitovaSchool configures it, deliberately: a
/// connection string and a sender address from the environment, and **blank is
/// a valid state** that selects the logging sender instead.
///
///   COMMS__CONNECTIONSTRING   endpoint=https://…;accesskey=…
///   COMMS__EMAILFROM          a verified sender address
///   COMMS__SMSFROM            a provisioned number or alphanumeric sender id
///
/// The signing below is the part worth reading. ACS authenticates with an HMAC
/// over the verb, the path, the date, the host and a hash of the body — so a
/// request cannot be replayed against a different route or with a different
/// payload. Getting the string-to-sign wrong produces a 401 with no hint as to
/// which of the five components was wrong, which is why each is built on its
/// own line here.
final class AcsNotificationGateway implements NotificationGateway {
  AcsNotificationGateway({
    required this.endpoint,
    required List<int> accessKey,
    required this.emailFrom,
    this.smsFrom,
    HttpClient? httpClient,
  }) : _accessKey = accessKey,
       _http = httpClient ?? HttpClient();

  final Uri endpoint;
  final List<int> _accessKey;
  final String emailFrom;
  final String? smsFrom;
  final HttpClient _http;

  /// Parses `endpoint=https://x.communication.azure.com/;accesskey=BASE64`.
  ///
  /// Null — not an exception — when the string is blank or unparseable, so
  /// composition can fall through to the logging sender. A misconfigured
  /// connection string must not stop the API from starting; it must stop it
  /// from *claiming to have sent* something.
  static AcsNotificationGateway? tryParse(
    String? connectionString, {
    required String? emailFrom,
    String? smsFrom,
    HttpClient? httpClient,
  }) {
    if (connectionString == null || connectionString.trim().isEmpty)
      return null;
    if (emailFrom == null || emailFrom.isEmpty) return null;

    String? endpoint;
    String? key;
    for (final part in connectionString.split(';')) {
      final at = part.indexOf('=');
      if (at < 0) continue;
      final name = part.substring(0, at).trim().toLowerCase();
      // The value is base64 and contains '='. Splitting on every '=' is the
      // bug this indexOf avoids.
      final value = part.substring(at + 1).trim();
      if (name == 'endpoint') endpoint = value;
      if (name == 'accesskey') key = value;
    }

    if (endpoint == null || key == null) return null;

    final parsed = Uri.tryParse(endpoint);
    if (parsed == null || !parsed.hasAuthority) return null;

    final List<int> decoded;
    try {
      decoded = base64.decode(key);
    } on FormatException {
      return null;
    }

    return AcsNotificationGateway(
      endpoint: parsed,
      accessKey: decoded,
      emailFrom: emailFrom,
      smsFrom: smsFrom,
      httpClient: httpClient,
    );
  }

  @override
  Future<NotifyFailure?> send(OutboundMessage message) =>
      switch (message.channel) {
        SignInChannel.email => _sendEmail(message),
        SignInChannel.phone => _sendSms(message),
      };

  Future<NotifyFailure?> _sendEmail(OutboundMessage message) => _post(
    '/emails:send',
    'api-version=2023-03-31',
    {
      'senderAddress': emailFrom,
      'content': {'subject': message.subject ?? '', 'plainText': message.body},
      'recipients': {
        'to': [
          {'address': message.to},
        ],
      },
    },
  );

  Future<NotifyFailure?> _sendSms(OutboundMessage message) {
    final from = smsFrom;
    // No provisioned sender is a configuration failure, not a bad number, and
    // saying so is what stops an afternoon being spent on the recipient.
    if (from == null || from.isEmpty) {
      return Future.value(NotifyFailure.railUnavailable);
    }

    return _post('/sms', 'api-version=2021-03-07', {
      'from': from,
      'message': message.body,
      'smsRecipients': [
        {'to': message.to},
      ],
    });
  }

  Future<NotifyFailure?> _post(
    String path,
    String query,
    Map<String, Object?> payload,
  ) async {
    final uri = endpoint.replace(path: path, query: query);
    final body = utf8.encode(jsonEncode(payload));

    try {
      final request = await _http.postUrl(uri);
      for (final header in _signedHeaders(uri, body).entries) {
        request.headers.set(header.key, header.value);
      }
      request.headers.contentType = ContentType.json;
      request.add(body);

      final response = await request.close();
      await response.drain<void>();

      return switch (response.statusCode) {
        >= 200 && < 300 => null,
        // ACS answers 400 for an address it will not accept. That is the
        // user's problem to fix and no amount of retrying changes it.
        400 || 404 => NotifyFailure.invalidRecipient,
        401 || 403 => NotifyFailure.rejected,
        _ => NotifyFailure.railUnavailable,
      };
    } on SocketException {
      return NotifyFailure.railUnavailable;
    } on HttpException {
      return NotifyFailure.railUnavailable;
    }
  }

  /// The five components ACS signs over, each on its own line so a 401 can be
  /// diagnosed by reading rather than by guessing.
  Map<String, String> _signedHeaders(Uri uri, List<int> body) {
    final date = HttpDate.format(DateTime.now().toUtc());
    final host = uri.host;
    final contentHash = base64.encode(sha256.convert(body).bytes);

    final pathAndQuery = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final stringToSign = 'POST\n$pathAndQuery\n$date;$host;$contentHash';

    final signature = base64.encode(
      Hmac(sha256, _accessKey).convert(utf8.encode(stringToSign)).bytes,
    );

    return {
      'x-ms-date': date,
      'x-ms-content-sha256': contentHash,
      'Authorization':
          'HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256'
          '&Signature=$signature',
    };
  }

  void close() => _http.close(force: true);
}
