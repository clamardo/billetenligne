import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/disbursement_gateway.dart';
import '../application/ports/payment_gateway.dart';
import 'mtn_momo_gateway.dart';

/// MTN MoMo **Disbursements** — money going out.
///
/// A separate product from Collections, and the separation is not cosmetic:
/// its own subscription key, its own API user and key, its own token endpoint,
/// its own base path, and a float the operator funds independently of what
/// they take in. Reusing the collection credentials here returns 401 on every
/// call; reusing the collection *base path* returns 404 on a status query,
/// which is worse — it reads as a transfer that vanished.
///
/// The vocabulary is otherwise identical, so the reason table and the amount
/// formatting are shared with [MtnMomoGateway] rather than copied. Two copies
/// would drift on the day MTN adds a reason to one of them.
final class MtnMomoDisbursementGateway implements DisbursementGateway {
  MtnMomoDisbursementGateway({
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

  final Uri baseUrl;

  /// **Not the collection subscription key.** MTN issues one per product, and
  /// the wrong one here is a 401 on every call with no useful body.
  final String subscriptionKey;
  final String apiUser;
  final String apiKey;
  final String targetEnvironment;
  final String callbackUrl;

  final Clock _clock;
  final HttpClient _http;

  String? _token;
  DateTime? _tokenExpiresAt;

  @override
  String get railId => 'cg.mtn_momo';

  @override
  Future<PaymentOutcome> disburse(DisbursementRequest request) async {
    try {
      final response = await _post(
        '/disbursement/v1_0/transfer',
        {
          'amount': MtnMomoGateway.amountFor(request.amount),
          'currency': request.amount.currency.code,
          'externalId': request.reference,
          'payee': {'partyIdType': 'MSISDN', 'partyId': request.payeeMsisdn},
          'payerMessage': request.description,
          'payeeNote': request.description,
        },
        headers: {
          // The transaction's identity AND its idempotency key. This is the
          // refund id, so asking twice for the same refund sends money once —
          // which is the only guarantee that makes a retryable worker safe.
          'X-Reference-Id': request.reference,
          'X-Callback-Url': callbackUrl,
        },
      );

      if (response.status == HttpStatus.accepted) {
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      return PaymentOutcome(
        state: PaymentState.failed,
        failureCode: MtnMomoGateway.refusalCodeFor(
          status: response.status,
          body: response.body,
        ),
        raw: response.body,
      );
    } on SocketException {
      // The transfer may or may not have been accepted. Reporting `failed`
      // here would send it a second time on the next pass, and the second one
      // would not be deduplicated by a rail that never saw the first.
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
      final response = await _get('/disbursement/v1_0/transfer/$reference');

      if (response.status != HttpStatus.ok) {
        // Never a failure. A 404 under this path after a successful 202 means
        // something is badly wrong — most often the collection credentials in
        // this adapter's slot — and a refund the traveller is owed must not be
        // closed by a question asked in the wrong place.
        return PaymentOutcome(state: PaymentState.pending, raw: response.body);
      }

      final status = '${response.body['status']}'.toUpperCase();
      return switch (status) {
        'SUCCESSFUL' => PaymentOutcome(
          state: PaymentState.captured,
          raw: response.body,
        ),
        'FAILED' => PaymentOutcome(
          state: PaymentState.failed,
          failureCode: MtnMomoGateway.failureCodeFor(
            '${response.body['reason']}',
          ),
          raw: response.body,
        ),
        _ => PaymentOutcome(state: PaymentState.pending, raw: response.body),
      };
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  // ── Transport ─────────────────────────────────────────────────────────────
  //
  // Deliberately not shared with the collection adapter. The token is scoped
  // to the product, so one cache holding "the MTN token" would hand a
  // Collections token to a Disbursements call the first time the two were
  // used in the same process — a 401 that appears only under load.

  Future<String> _accessToken() async {
    final expiry = _tokenExpiresAt;
    if (_token != null &&
        expiry != null &&
        _clock.now().add(const Duration(minutes: 1)).isBefore(expiry)) {
      return _token!;
    }

    final request = await _http.postUrl(
      baseUrl.replace(path: '/disbursement/token/'),
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
