import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/payment_gateway.dart';

/// MTN MoMo Collections.
///
/// Two things about this API shape the adapter:
///
///   * **`X-Reference-Id` IS the transaction.** We generate it, it is our
///     intent id, and it is both the idempotency key and the handle every
///     subsequent query uses. There is no separate identifier to store, which
///     is why `railTransactionId` comes back null here and non-null for
///     Airtel.
///   * **`requesttopay` returns 202 and nothing else.** The traveller has not
///     typed their PIN yet. Status is PENDING until they authorise, decline,
///     or the system times them out, and it is read from
///     `GET /requesttopay/{referenceId}`.
///
/// The access token is a client-credentials exchange against
/// `/collection/token/` using the API user and key; it lives about an hour and
/// is cached until shortly before it expires.
final class MtnMomoGateway implements PaymentGateway {
  MtnMomoGateway({
    required this.baseUrl,
    required this.subscriptionKey,
    required this.apiUser,
    required this.apiKey,
    required this.targetEnvironment,
    required this.callbackUrl,
    Clock clock = const SystemClock(),
    HttpClient? httpClient,
  }) : _clock = clock,
       _http = httpClient ?? HttpClient();

  /// `https://sandbox.momodeveloper.mtn.com` or the production host.
  final Uri baseUrl;

  final String subscriptionKey;
  final String apiUser;
  final String apiKey;

  /// `sandbox`, or the production environment name MTN issues per market.
  /// Wrong here is a 500 with no useful body, so it is configuration rather
  /// than a constant.
  final String targetEnvironment;

  final String callbackUrl;

  final Clock _clock;
  final HttpClient _http;

  String? _token;
  DateTime? _tokenExpiresAt;

  @override
  String get railId => 'cg.mtn_momo';

  /// A prompt on the payer's own handset, answered with a PIN in a menu we do
  /// not control — which is the asynchrony ADR-0005 exists to contain.
  @override
  bool get pushesToHandset => true;

  @override
  Future<PaymentOutcome> requestPayment(PaymentRequest request) async {
    try {
      final response = await _post(
        '/collection/v1_0/requesttopay',
        {
          'amount': _amount(request.amount),
          'currency': request.amount.currency.code,
          // Ours, echoed back on every status query. MTN calls it
          // externalId; it is what a support agent matches on.
          'externalId': request.reference,
          // Absent only if a card rail's request reached a push adapter,
          // which is a wiring mistake rather than a payment that should be
          // attempted against "".
          'payer': {
            'partyIdType': 'MSISDN',
            'partyId':
                request.payerMsisdn ??
                (throw StateError('a push rail was given no payer number')),
          },
          // Both appear in the USSD prompt on the handset. Short, because a
          // feature phone shows a couple of lines.
          'payerMessage': request.description,
          'payeeNote': request.reference,
        },
        headers: {
          // The transaction's identity AND its idempotency key. Repeating it
          // returns the existing transaction rather than creating a second.
          'X-Reference-Id': request.intentId,
          'X-Callback-Url': callbackUrl,
        },
      );

      // 202 means the prompt is on its way, not that money moved. Anything
      // else is a refusal by the rail before the handset was ever involved.
      if (response.status == HttpStatus.accepted) {
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      return PaymentOutcome(
        state: PaymentState.failed,
        failureCode: _refusalCode(response),
        raw: response.body,
      );
    } on SocketException {
      // The push may or may not have reached the handset and the money may or
      // may not have moved. `failed` here is a lie that costs a customer their
      // seat; `pending` is the truth and the poller resolves it.
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
      final response = await _get('/collection/v1_0/requesttopay/$intentId');

      if (response.status != HttpStatus.ok) {
        // A 404 from MTN means it has never heard of this reference, which
        // after a successful 202 means something is badly wrong — not that
        // the payment failed. Kept in flight for a human to look at.
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      final status = '${response.body['status']}'.toUpperCase();
      return switch (status) {
        'SUCCESSFUL' => PaymentOutcome(
          state: PaymentState.captured,
          raw: response.body,
        ),
        'PENDING' => PaymentOutcome(
          state: PaymentState.pending,
          raw: response.body,
        ),
        'FAILED' => PaymentOutcome(
          state: PaymentState.failed,
          failureCode: failureCodeFor('${response.body['reason']}'),
          raw: response.body,
        ),
        // An unrecognised status is not a failure. MTN adds values; treating
        // an unknown one as failed would refuse money that had moved.
        _ => PaymentOutcome(state: PaymentState.pending, raw: response.body),
      };
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  /// MTN's documented reasons, mapped onto our taxonomy.
  ///
  /// Every one of these has its own sentence and its own recovery in the app
  /// (`04-payments.md` §5) — "Payment failed. Try again." is what this mapping
  /// exists to prevent.
  ///
  /// Public because the Disbursements product answers with the same vocabulary
  /// under a different base path, and two copies of this table would drift on
  /// the day MTN adds a reason to one of them.
  static PaymentFailureCode failureCodeFor(String reason) =>
      switch (reason.toUpperCase()) {
        'NOT_ENOUGH_FUNDS' => PaymentFailureCode.insufficientFunds,
        'PAYER_LIMIT_REACHED' => PaymentFailureCode.limitExceeded,
        'PAYEE_NOT_FOUND' ||
        'PAYER_NOT_FOUND' => PaymentFailureCode.subscriberNotFound,
        'PAYER_NOT_ALLOWED_TO_RECEIVE' ||
        'NOT_ALLOWED' ||
        'NOT_ALLOWED_TARGET_ENVIRONMENT' => PaymentFailureCode.subscriberBarred,
        'APPROVAL_REJECTED' => PaymentFailureCode.userDeclined,
        'EXPIRED' => PaymentFailureCode.timeoutNoResponse,
        'INTERNAL_PROCESSING_ERROR' ||
        'SERVICE_UNAVAILABLE' => PaymentFailureCode.pspUnavailable,
        _ => PaymentFailureCode.pspUnavailable,
      };

  static PaymentFailureCode _refusalCode(_Response response) =>
      refusalCodeFor(status: response.status, body: response.body);

  /// A refusal made before the handset was ever involved. Shared with the
  /// Disbursements adapter for the same reason [failureCodeFor] is.
  static PaymentFailureCode refusalCodeFor({
    required int status,
    required Map<String, Object?> body,
  }) {
    final code = '${body['code'] ?? ''}';
    if (code.isNotEmpty) return failureCodeFor(code);
    return status == HttpStatus.badRequest
        ? PaymentFailureCode.subscriberNotFound
        : PaymentFailureCode.pspUnavailable;
  }

  /// The amount as MTN wants it: a decimal string, with no minor unit on XAF.
  /// Public for the Disbursements adapter, which must format it identically —
  /// `"93.00"` where `"9300"` was meant pays ninety-three francs, and succeeds.
  static String amountFor(Money amount) => _amount(amount);

  /// MTN wants a decimal string even for a zero-decimal currency.
  ///
  /// XAF has no minor unit, so 9 300 francs is `"9300"` and not `"93.00"`.
  /// Sending the latter would pay ninety-three francs, and it would succeed.
  static String _amount(Money amount) => amount.currency.exponent == 0
      ? '${amount.minor}'
      : (amount.minor / _pow10(amount.currency.exponent)).toStringAsFixed(
          amount.currency.exponent,
        );

  static int _pow10(int exponent) {
    var value = 1;
    for (var i = 0; i < exponent; i++) {
      value *= 10;
    }
    return value;
  }

  // ── Transport ─────────────────────────────────────────────────────────────

  Future<String> _accessToken() async {
    final expiry = _tokenExpiresAt;
    // A minute of headroom: a token that expires while the request carrying it
    // is in flight fails the one call that mattered.
    if (_token != null &&
        expiry != null &&
        _clock.now().add(const Duration(minutes: 1)).isBefore(expiry)) {
      return _token!;
    }

    final request = await _http.postUrl(
      baseUrl.replace(path: '/collection/token/'),
    );
    request.headers
      ..set('Ocp-Apim-Subscription-Key', subscriptionKey)
      ..set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64.encode(utf8.encode('$apiUser:$apiKey'))}',
      );

    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    if (body is! Map || body['access_token'] is! String) {
      throw const HttpException('MTN token response had no access_token');
    }

    _token = body['access_token'] as String;
    _tokenExpiresAt = _clock.now().add(
      Duration(seconds: int.tryParse('${body['expires_in']}') ?? 3000),
    );
    return _token!;
  }

  Future<_Response> _post(
    String path,
    Map<String, Object?> payload, {
    Map<String, String> headers = const {},
  }) async {
    final token = await _accessToken();
    final request = await _http.postUrl(baseUrl.replace(path: path));

    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('Ocp-Apim-Subscription-Key', subscriptionKey)
      ..set('X-Target-Environment', targetEnvironment)
      ..contentType = ContentType.json;
    for (final header in headers.entries) {
      request.headers.set(header.key, header.value);
    }

    request.add(utf8.encode(jsonEncode(payload)));
    return _read(await request.close());
  }

  Future<_Response> _get(String path) async {
    final token = await _accessToken();
    final request = await _http.getUrl(baseUrl.replace(path: path));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('Ocp-Apim-Subscription-Key', subscriptionKey)
      ..set('X-Target-Environment', targetEnvironment);
    return _read(await request.close());
  }

  static Future<_Response> _read(HttpClientResponse response) async {
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
