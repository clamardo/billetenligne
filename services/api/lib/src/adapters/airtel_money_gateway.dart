import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/payment_gateway.dart';

/// Airtel Money Collections — USSD push.
///
/// Shaped differently from MTN in three ways that matter to the adapter:
///
///   * **Airtel mints its own transaction id** and returns it in the response.
///     Our reference travels as `transaction.id` and comes back on callbacks,
///     but a status query keys on *their* id — which is why this adapter
///     returns a `railTransactionId` and MTN's does not.
///   * **Country and currency are headers**, `X-Country` and `X-Currency`, not
///     body fields. Omitting them is a 403 that reads like an auth problem.
///   * **The initiate response carries a status already.** Airtel answers with
///     a `status.code`, and `TS`/`TF` there means the push was accepted or
///     refused — it does not mean the traveller has typed their PIN.
///
/// Auth is OAuth2 client credentials against `/auth/oauth2/token`.
final class AirtelMoneyGateway implements PaymentGateway {
  AirtelMoneyGateway({
    required this.baseUrl,
    required this.clientId,
    required this.clientSecret,
    required this.country,
    required this.currency,
    Clock clock = const SystemClock(),
    HttpClient? httpClient,
  }) : _clock = clock,
       _http = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String clientId;
  final String clientSecret;

  /// ISO country, `CG` for Congo-Brazzaville.
  final String country;

  /// ISO currency, `XAF`.
  final String currency;

  final Clock _clock;
  final HttpClient _http;

  String? _token;
  DateTime? _tokenExpiresAt;

  @override
  String get railId => 'cg.airtel_money';

  @override
  Future<PaymentOutcome> requestPayment(PaymentRequest request) async {
    try {
      final response = await _send('POST', '/merchant/v1/payments/', {
        'reference': request.reference,
        'subscriber': {
          'country': country,
          'currency': request.amount.currency.code,
          // The wallet the money comes FROM. Airtel wants it without the
          // country code, which is the opposite of how we store it — and
          // sending E.164 here is a subscriber-not-found that looks like a
          // wrong number.
          'msisdn': _national(request.payerMsisdn),
        },
        'transaction': {
          'amount': _amount(request.amount),
          'country': country,
          'currency': request.amount.currency.code,
          // Ours. Echoed on the callback, which is how an untrusted callback
          // is matched to an intent before we re-query.
          'id': request.intentId,
        },
      });

      final status = _statusCode(response.body);

      // `TIP` / `TS` means the prompt is out. The traveller has not typed
      // anything yet, so this is pending and not a capture.
      if (status == 'TS' || status == 'TIP' || status == 'TIPP') {
        return PaymentOutcome(
          state: PaymentState.pending,
          railTransactionId: _transactionId(response.body),
          raw: response.body,
        );
      }

      if (response.status >= 200 && response.status < 300 && status.isEmpty) {
        return PaymentOutcome(
          state: PaymentState.pending,
          railTransactionId: _transactionId(response.body),
          raw: response.body,
        );
      }

      return PaymentOutcome(
        state: PaymentState.failed,
        failureCode: _failureCode(status, response.body),
        railTransactionId: _transactionId(response.body),
        raw: response.body,
      );
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  @override
  Future<PaymentOutcome> queryStatus({
    required String intentId,
    String? railTransactionId,
  }) async {
    try {
      // Keyed on OUR id, which Airtel accepts on this endpoint and which is
      // the only one we are certain to have: a request that timed out before
      // its response arrived left us with no rail id at all, and that is
      // exactly the case a status query exists for.
      final response = await _send(
        'GET',
        '/standard/v1/payments/$intentId',
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
          failureCode: _failureCode(
            _statusCode(response.body),
            response.body,
          ),
          raw: response.body,
        ),
        'TA' || 'TIP' => PaymentOutcome(
          state: PaymentState.pending,
          raw: response.body,
        ),
        // Unknown means unknown. Airtel adds codes, and treating one we have
        // not seen as a failure would refuse money that had moved.
        _ => PaymentOutcome(state: PaymentState.pending, raw: response.body),
      };
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  /// Airtel's result codes, mapped onto our taxonomy.
  static PaymentFailureCode _failureCode(
    String status,
    Map<String, Object?> body,
  ) {
    final message = '${_statusField(body, 'message')}'.toUpperCase();

    if (message.contains('INSUFFICIENT') || message.contains('BALANCE')) {
      return PaymentFailureCode.insufficientFunds;
    }
    if (message.contains('PIN')) return PaymentFailureCode.wrongPin;
    if (message.contains('LIMIT')) return PaymentFailureCode.limitExceeded;
    if (message.contains('EXPIRE') || message.contains('TIMEOUT')) {
      return PaymentFailureCode.timeoutNoResponse;
    }
    if (message.contains('SUBSCRIBER') || message.contains('NOT FOUND')) {
      return PaymentFailureCode.subscriberNotFound;
    }
    if (message.contains('BARRED') || message.contains('BLOCKED')) {
      return PaymentFailureCode.subscriberBarred;
    }
    if (message.contains('CANCEL') || message.contains('REJECT')) {
      return PaymentFailureCode.userDeclined;
    }
    return status == 'TF'
        ? PaymentFailureCode.userDeclined
        : PaymentFailureCode.pspUnavailable;
  }

  static String _statusCode(Map<String, Object?> body) =>
      '${_statusField(body, 'code') ?? _statusField(body, 'result_code') ?? ''}'
          .toUpperCase();

  static Object? _statusField(Map<String, Object?> body, String field) =>
      ((body['status'] as Map?)?.cast<String, Object?>())?[field];

  static String? _transactionId(Map<String, Object?> body) {
    final data = (body['data'] as Map?)?.cast<String, Object?>();
    final transaction = (data?['transaction'] as Map?)?.cast<String, Object?>();
    final id = transaction?['id'];
    return id == null ? null : '$id';
  }

  /// Airtel wants the national number, not E.164.
  ///
  /// We store `242061234567`; this sends `061234567`. Sending the stored form
  /// produces a subscriber-not-found that looks, to everybody reading the
  /// log, like the traveller mistyped their number.
  static String _national(String e164) {
    const countryCode = '242';
    return e164.startsWith(countryCode)
        ? e164.substring(countryCode.length)
        : e164;
  }

  /// Whole units. XAF has no minor unit, so 9 300 francs is `9300`.
  static num _amount(Money amount) {
    if (amount.currency.exponent == 0) return amount.minor;
    var divisor = 1;
    for (var i = 0; i < amount.currency.exponent; i++) {
      divisor *= 10;
    }
    return amount.minor / divisor;
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

  Future<_AirtelResponse> _send(
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
      // Headers, not body fields. Omitting them is a 403 that reads like an
      // auth problem and costs an afternoon.
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
    return _AirtelResponse(response.statusCode, body);
  }

  void close() => _http.close(force: true);
}

final class _AirtelResponse {
  const _AirtelResponse(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}
