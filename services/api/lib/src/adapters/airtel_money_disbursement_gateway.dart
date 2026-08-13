import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/disbursement_gateway.dart';
import '../application/ports/payment_gateway.dart';
import 'airtel_money_gateway.dart';

/// Airtel Money **Disbursements** — money going out.
///
/// The same OAuth2 credentials as Collections, and that is the one place this
/// rail is simpler than MTN. Everything else it does differently, in ways that
/// each cost an afternoon if guessed:
///
///   * **The resource is `/standard/v1/disbursements/`**, and a status query
///     reads back from the same path keyed on **our** id. Querying the
///     payments path with a disbursement id answers 404, which reads as a
///     refund that vanished.
///   * **It wants an encrypted PIN.** Airtel authorises a payout with the
///     merchant's own wallet PIN, RSA-encrypted under a public key they issue.
///     This adapter takes the already-encrypted blob as configuration: doing
///     the encryption here would mean holding the plaintext PIN in this
///     process, and it is the one credential that authorises money leaving.
///   * **`msisdn` is national, not E.164** — the same trap as the collection
///     side, and the same consequence: a subscriber-not-found that reads like
///     the traveller mistyped their number.
final class AirtelMoneyDisbursementGateway implements DisbursementGateway {
  AirtelMoneyDisbursementGateway({
    required this.baseUrl,
    required this.clientId,
    required this.clientSecret,
    required this.country,
    required this.currency,
    required this.encryptedPin,
    Clock clock = const SystemClock(),
    HttpClient? httpClient,
  }) : _clock = clock,
       _http = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String clientId;
  final String clientSecret;
  final String country;
  final String currency;

  /// The merchant wallet PIN, already RSA-encrypted under Airtel's public key.
  ///
  /// Configuration rather than something computed here on purpose: the
  /// plaintext PIN is the single credential that authorises money leaving, and
  /// a process that never holds it cannot leak it in a heap dump, a log line
  /// or a core file.
  final String encryptedPin;

  final Clock _clock;
  final HttpClient _http;

  String? _token;
  DateTime? _tokenExpiresAt;

  @override
  String get railId => 'cg.airtel_money';

  @override
  Future<PaymentOutcome> disburse(DisbursementRequest request) async {
    try {
      final response = await _send('POST', '/standard/v1/disbursements/', {
        'payee': {
          'msisdn': AirtelMoneyGateway.nationalNumber(request.payeeMsisdn),
          'currency': request.amount.currency.code,
        },
        'reference': request.description,
        'pin': encryptedPin,
        'transaction': {
          'amount': AirtelMoneyGateway.amountFor(request.amount),
          // Ours, and the idempotency key: this is the refund id, so asking
          // twice sends money once.
          'id': request.reference,
        },
      });

      final status = AirtelMoneyGateway.statusCodeOf(response.body);

      // `TS` on the initiate means accepted, not settled. Airtel answers a
      // disbursement faster than a collection — there is no handset to wait
      // for — but the money is still confirmed by asking, never by this.
      if (status == 'TS' || status == 'TIP' || status == 'TIPP') {
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      if (response.status >= 200 && response.status < 300 && status.isEmpty) {
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      return PaymentOutcome(
        state: PaymentState.failed,
        failureCode: AirtelMoneyGateway.failureCodeFor(status, response.body),
        raw: response.body,
      );
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  @override
  Future<PaymentOutcome> queryDisbursement({
    required String reference,
    String? railTransactionId,
  }) async {
    try {
      final response = await _send(
        'GET',
        '/standard/v1/disbursements/$reference',
        null,
      );

      if (response.status != HttpStatus.ok) {
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      final data = (response.body['data'] as Map?)?.cast<String, Object?>();
      final transaction =
          (data?['transaction'] as Map?)?.cast<String, Object?>() ?? const {};
      final status = '${transaction['status'] ?? ''}'.toUpperCase();

      return switch (status) {
        'TS' => PaymentOutcome(
          state: PaymentState.captured,
          railTransactionId: '${transaction['airtel_money_id'] ?? ''}',
          raw: response.body,
        ),
        'TF' => PaymentOutcome(
          state: PaymentState.failed,
          failureCode: AirtelMoneyGateway.failureCodeFor(
            AirtelMoneyGateway.statusCodeOf(response.body),
            response.body,
          ),
          raw: response.body,
        ),
        // Unknown means unknown. A code we have not seen is not a refusal, and
        // treating it as one would close a refund the traveller is owed.
        _ => PaymentOutcome(state: PaymentState.pending, raw: response.body),
      };
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  // ── Transport ─────────────────────────────────────────────────────────────

  Future<String> _accessToken() async {
    final expiry = _tokenExpiresAt;
    if (_token != null &&
        expiry != null &&
        _clock.now().add(const Duration(minutes: 1)).isBefore(expiry)) {
      return _token!;
    }

    final request = await _http.postUrl(
      baseUrl.replace(path: '/auth/oauth2/token'),
    );
    request.headers.contentType = ContentType.json;
    request.add(
      utf8.encode(
        jsonEncode({
          'client_id': clientId,
          'client_secret': clientSecret,
          'grant_type': 'client_credentials',
        }),
      ),
    );

    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    if (body is! Map || body['access_token'] is! String) {
      throw const HttpException('Airtel token response had no access_token');
    }

    _token = body['access_token'] as String;
    _tokenExpiresAt = _clock.now().add(
      Duration(seconds: int.tryParse('${body['expires_in']}') ?? 3000),
    );
    return _token!;
  }

  Future<_Response> _send(
    String method,
    String path,
    Map<String, Object?>? payload,
  ) async {
    final token = await _accessToken();
    final url = baseUrl.replace(path: path);
    final request = method == 'GET'
        ? await _http.getUrl(url)
        : await _http.postUrl(url);

    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('X-Country', country)
      ..set('X-Currency', currency)
      ..set(HttpHeaders.acceptHeader, 'application/json');

    if (payload != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(payload)));
    }

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    Map<String, Object?> body = const {};
    if (text.trim().isNotEmpty) {
      final decoded = jsonDecode(text);
      if (decoded is Map) body = decoded.cast<String, Object?>();
    }
    return _Response(response.statusCode, body);
  }

  void close() => _http.close(force: true);
}

final class _Response {
  const _Response(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}
