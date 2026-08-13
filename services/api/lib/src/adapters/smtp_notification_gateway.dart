import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bel_contracts/bel_contracts.dart';

import '../application/ports/notification_gateway.dart';

/// Email over plain SMTP, for the local stack (ADR-0020).
///
/// **Why this exists at all.** `infra/dev` runs Mailpit, and until now nothing
/// wrote to it: a sign-in code went to the API's stdout, an operator statement
/// went to stdout with `(+1: releve.pdf)` where the PDF should have been, and
/// the one thing a developer most needs to *look at* — the email a customer
/// receives — could not be looked at. A mail catcher with no sender is a
/// service in the compose file that lies about what the stack does.
///
/// **Development only, and structurally so.** No TLS, no authentication, no
/// retry, no queue. It is selected by `SMTP__HOST` pointing at a host that is
/// almost always `localhost`, and production selects ACS by having a
/// connection string — the two cannot both be chosen, because composition
/// asks for ACS first.
///
/// SMS is not sent here: there is no such thing as SMS over SMTP, and
/// pretending otherwise by mailing the text somewhere would be a channel that
/// looks delivered and is not. SMS falls back to the log, which is honest and
/// is what a developer reads anyway.
final class SmtpNotificationGateway implements NotificationGateway {
  const SmtpNotificationGateway({
    required this.host,
    required this.port,
    required this.emailFrom,
    this.fallback = const LoggingSink(),
    this.timeout = const Duration(seconds: 5),
  });

  final String host;
  final int port;
  final String emailFrom;

  /// Where SMS goes, and where email goes when the mail catcher is not
  /// running. A developer who stopped the compose stack should still be able
  /// to read the code they are waiting for.
  final NotificationGateway fallback;

  /// Short. A local mail catcher answers in milliseconds; anything slower is
  /// a container that is not there, and a sign-in request must not hang on it.
  final Duration timeout;

  /// Null when no host is configured, so composition falls through.
  static SmtpNotificationGateway? tryParse(
    String? host, {
    String? port,
    required String? emailFrom,
    NotificationGateway fallback = const LoggingSink(),
  }) {
    if (host == null || host.trim().isEmpty) return null;
    final parsed = int.tryParse(port?.trim() ?? '');
    if (port != null && port.trim().isNotEmpty && parsed == null) return null;
    return SmtpNotificationGateway(
      host: host.trim(),
      port: parsed ?? 1025,
      emailFrom: (emailFrom?.trim().isNotEmpty ?? false)
          ? emailFrom!.trim()
          : 'no-reply@billetenligne.local',
      fallback: fallback,
    );
  }

  @override
  Future<NotifyFailure?> send(OutboundMessage message) async {
    if (message.channel != SignInChannel.email) {
      return fallback.send(message);
    }

    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      final replies = _Replies(socket, timeout);

      await replies.expect(220);
      await _say(socket, replies, 'EHLO billetenligne.local', 250);
      await _say(socket, replies, 'MAIL FROM:<$emailFrom>', 250);
      await _say(socket, replies, 'RCPT TO:<${message.to}>', 250);
      await _say(socket, replies, 'DATA', 354);

      socket.write(_mime(message));
      await socket.flush();
      await replies.expect(250);

      socket.write('QUIT\r\n');
      await socket.flush();
      return null;
    } on Object {
      // Never a failure the caller acts on: the mail catcher being down is a
      // fact about this laptop, not about the address. Falling through to the
      // log keeps a developer unblocked instead of teaching them that sign-in
      // is broken.
      return fallback.send(message);
    } finally {
      await socket?.close();
    }
  }

  Future<void> _say(
    Socket socket,
    _Replies replies,
    String line,
    int expected,
  ) async {
    socket.write('$line\r\n');
    await socket.flush();
    await replies.expect(expected);
  }

  /// The message as bytes on the wire.
  ///
  /// Multipart only when there is something to be multipart about: a sign-in
  /// code is one short paragraph, and wrapping it in MIME boundaries makes it
  /// harder to read in the one place it will be read.
  String _mime(OutboundMessage message) {
    final headers = StringBuffer()
      ..write('From: $emailFrom\r\n')
      ..write('To: ${message.to}\r\n')
      ..write('Subject: ${_encodeHeader(message.subject ?? '')}\r\n')
      ..write('MIME-Version: 1.0\r\n');

    if (message.attachments.isEmpty && message.html == null) {
      headers
        ..write('Content-Type: text/plain; charset=utf-8\r\n')
        ..write('Content-Transfer-Encoding: base64\r\n\r\n')
        ..write(_wrap(base64.encode(utf8.encode(message.body))))
        ..write('\r\n.\r\n');
      return headers.toString();
    }

    // Derived from the recipient and the body length rather than from a
    // random source: a boundary that collides with the body is the classic
    // way an attachment eats the message, and this is deterministic enough to
    // reproduce and unlikely enough not to collide.
    final boundary =
        'bel${message.to.hashCode.abs()}x${message.body.length}x'
        '${Random(message.body.length).nextInt(1 << 32)}';

    headers
      ..write('Content-Type: multipart/mixed; boundary="$boundary"\r\n\r\n')
      ..write('--$boundary\r\n')
      ..write('Content-Type: text/plain; charset=utf-8\r\n')
      ..write('Content-Transfer-Encoding: base64\r\n\r\n')
      ..write(_wrap(base64.encode(utf8.encode(message.body))))
      ..write('\r\n');

    if (message.html != null) {
      headers
        ..write('--$boundary\r\n')
        ..write('Content-Type: text/html; charset=utf-8\r\n')
        ..write('Content-Transfer-Encoding: base64\r\n\r\n')
        ..write(_wrap(base64.encode(utf8.encode(message.html!))))
        ..write('\r\n');
    }

    for (final a in message.attachments) {
      headers
        ..write('--$boundary\r\n')
        ..write('Content-Type: ${a.contentType}; name="${a.name}"\r\n')
        ..write('Content-Disposition: attachment; filename="${a.name}"\r\n')
        ..write('Content-Transfer-Encoding: base64\r\n\r\n')
        ..write(_wrap(base64.encode(a.bytes)))
        ..write('\r\n');
    }

    headers
      ..write('--$boundary--\r\n')
      ..write('.\r\n');
    return headers.toString();
  }

  /// RFC 2047, because *Votre code* and *Réservation confirmée* are the
  /// subjects this actually sends and a raw accent in a header is mojibake in
  /// the inbox list.
  static String _encodeHeader(String raw) => raw.codeUnits.every((c) => c < 128)
      ? raw
      : '=?UTF-8?B?${base64.encode(utf8.encode(raw))}?=';

  /// 76 characters, because SMTP lines are bounded and a 20 KB QR on one line
  /// is a message some servers truncate and others refuse.
  static String _wrap(String encoded) {
    final out = StringBuffer();
    for (var i = 0; i < encoded.length; i += 76) {
      out.write(encoded.substring(i, min(i + 76, encoded.length)));
      out.write('\r\n');
    }
    return out.toString();
  }
}

/// Reads SMTP reply codes off the socket, one command at a time.
final class _Replies {
  _Replies(Socket socket, this._timeout)
    : _lines = const LineSplitter()
          .bind(utf8.decoder.bind(socket))
          // Multi-line replies use `250-` for every line but the last, which
          // uses `250 `. Only the last one answers the command.
          .where((l) => l.length < 4 || l[3] != '-')
          .asBroadcastStream();

  final Stream<String> _lines;
  final Duration _timeout;

  Future<void> expect(int code) async {
    final line = await _lines.first.timeout(_timeout);
    final got = int.tryParse(line.length >= 3 ? line.substring(0, 3) : '');
    if (got != code) {
      throw StateError('SMTP expected $code, got: $line');
    }
  }
}

/// The log, as a gateway. Split out so [SmtpNotificationGateway] can default
/// its fallback without importing the composition that would import it back.
final class LoggingSink implements NotificationGateway {
  const LoggingSink();

  @override
  Future<NotifyFailure?> send(OutboundMessage message) async {
    stdout.writeln(
      '[${message.channel.name.toUpperCase()} → ${message.to}] '
      '${message.subject == null ? '' : '${message.subject}: '}'
      '${message.body}',
    );
    return null;
  }
}
