import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/payment_gateway.dart';

/// Orange Money — the largest wallet in this market, and the one that does
/// not push.
///
/// **It is a hosted checkout, not a USSD push**, and that is the fact the
/// whole adapter turns on. MTN and Airtel take a number and ring a handset;
/// Orange's Web Payment API takes an order and answers with a page, the
/// traveller authorises it on Orange's own site, and we find out by asking.
/// Everything that needs is already built — it is the same shape a card
/// takes — so this rail cost a class rather than a second payment funnel.
/// `pushesToHandset` existing as a question asked of the rail rather than a
/// list of rail ids is exactly what made that true.
///
/// Three things differ from the wallet adapters beside it:
///
///   * **No payer number.** The traveller types their own on Orange's page.
///     Sending one would be a field Orange ignores and a wrong-number support
///     call we invented ourselves.
///   * **A merchant key, not a collection wallet.** The money lands in the
///     operator's Orange merchant account; `merchant_key` is what names it,
///     and getting it wrong is a payment that succeeds into somebody else's
///     balance.
///   * **`order_id` is ours and travels everywhere.** It is echoed on the
///     notification and required on every status query, which is what lets an
///     untrusted callback be matched to an intent before we re-query
///     (ADR-0005 rule 4).
///
/// **Written against no merchant key.** There is no Orange contract for this
/// deployment yet, so what this targets is the Web Payment API as published —
/// `/oauth/v3/token` for client credentials, `/orange-money-webpay/{country}/
/// v1/webpayment` to create, `/transactionstatus` to ask. If the eventual
/// contract turns out to be Orange's merchant-*push* API instead, this file
/// is what changes: `pushesToHandset` becomes true, `requestPayment` sends a
/// subscriber number, and nothing above this file moves at all. That is the
/// whole point of the port.
final class OrangeMoneyGateway implements PaymentGateway {
  OrangeMoneyGateway({
    required this.baseUrl,
    required this.clientId,
    required this.clientSecret,
    required this.merchantKey,
    required this.returnUrl,
    required this.cancelUrl,
    required this.callbackUrl,
    this.country = 'cg',
    this.railId = 'cg.orange_money',
    Clock clock = const SystemClock(),
    HttpClient? httpClient,
  }) : _clock = clock,
       _http = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String clientId;
  final String clientSecret;

  /// Which merchant account the money lands in.
  final String merchantKey;

  /// Where Orange sends the traveller when they are finished, and when they
  /// give up. Both are browser redirects and neither decides anything: the
  /// capture is confirmed by asking Orange, exactly as a callback is.
  final String returnUrl;
  final String cancelUrl;

  /// Where Orange tells us, server to server. Untrusted like every other
  /// callback: it wakes the re-query, it does not decide.
  final String callbackUrl;

  /// In the path, lower case — `cg` for Congo-Brazzaville, `dev` for the
  /// sandbox. A country in the wrong case is a 404 that reads like an outage.
  final String country;

  @override
  final String railId;

  final Clock _clock;
  final HttpClient _http;

  String? _token;
  DateTime? _tokenExpiresAt;

  /// Nothing rings. The traveller authorises on Orange's page.
  @override
  bool get pushesToHandset => false;

  /// What each order was answered with, so a status query can send the token
  /// back. Orange requires `pay_token` on every check, and it is not derivable
  /// from anything else we hold.
  ///
  /// In memory on purpose: the durable copy is `payment_intents.psp_reference`,
  /// written by the store from `railTransactionId`, and this map is only the
  /// same process's shortcut. A restart falls back to the stored one.
  final _payTokens = <String, String>{};

  @override
  Future<PaymentOutcome> requestPayment(PaymentRequest request) async {
    try {
      final response = await _send(
        '/orange-money-webpay/$country/v1/webpayment',
        {
          'merchant_key': merchantKey,
          'currency': request.amount.currency.code,
          // Ours, and the handle every later query and every notification uses.
          'order_id': request.intentId,
          'amount': _amount(request.amount),
          'return_url': request.returnUrl ?? returnUrl,
          'cancel_url': cancelUrl,
          'notif_url': callbackUrl,
          // The page Orange draws is in the traveller's language or it is in
          // nobody's. French is the market's source language (ADR-0008).
          'lang': 'fr',
          // Printed on the traveller's Orange statement. A booking reference is
          // the one string that means something to them six weeks later.
          'reference': request.reference,
        },
      );

      final url = response.body['payment_url'];
      final token = response.body['pay_token'];

      if (url is String && url.isNotEmpty && token is String) {
        _payTokens[request.intentId] = token;
        // Pending, not authorised: the page exists and nobody has been to it.
        return PaymentOutcome(
          state: PaymentState.pending,
          checkoutUrl: url,
          railTransactionId: token,
          raw: response.body,
        );
      }

      return PaymentOutcome(
        state: PaymentState.failed,
        failureCode: PaymentFailureCode.pspUnavailable,
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
    final token = railTransactionId ?? _payTokens[intentId];
    // Without the token there is no question to ask. Unknown rather than
    // failed: an intent whose creation response was lost may still have a
    // page somebody has already paid on.
    if (token == null) return PaymentOutcome.unknown;

    try {
      final response = await _send(
        '/orange-money-webpay/$country/v1/transactionstatus',
        {'order_id': intentId, 'pay_token': token},
      );
      return _statusOf(response);
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  /// Orange's vocabulary, mapped onto ours.
  ///
  /// An **unrecognised status is pending**, never failed. Orange adds values,
  /// and treating one we have not seen as a failure refuses money that has
  /// already moved.
  PaymentOutcome _statusOf(_Response response) {
    final status = '${response.body['status'] ?? ''}'.toUpperCase();

    return switch (status) {
      'SUCCESS' || 'SUCCESSFUL' => PaymentOutcome(
        state: PaymentState.captured,
        railTransactionId: '${response.body['txnid'] ?? ''}'.isEmpty
            ? null
            : '${response.body['txnid']}',
        raw: response.body,
      ),
      'FAILED' || 'FAILURE' => PaymentOutcome(
        state: PaymentState.failed,
        failureCode: PaymentFailureCode.userDeclined,
        raw: response.body,
      ),
      // The page was created and the traveller ran out of time. Terminal, and
      // its own code: "the payment window closed" is a different sentence and
      // a different recovery from "your payment was refused".
      'EXPIRED' => PaymentOutcome(
        state: PaymentState.failed,
        failureCode: PaymentFailureCode.timeoutNoResponse,
        raw: response.body,
      ),
      _ => PaymentOutcome(state: PaymentState.pending, raw: response.body),
    };
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

  /// Client credentials, cached until a minute before they lapse.
  ///
  /// Basic auth on the token call and Bearer everywhere else, which is the
  /// one asymmetry in this API worth writing down: sending the bearer to the
  /// token endpoint is a 401 that looks like bad credentials.
  Future<String> _accessToken() async {
    final expiry = _tokenExpiresAt;
    if (_token != null &&
        expiry != null &&
        _clock.now().add(const Duration(minutes: 1)).isBefore(expiry)) {
      return _token!;
    }

    final request = await _http.postUrl(baseUrl.resolve('/oauth/v3/token'));
    final basic = base64.encode(utf8.encode('$clientId:$clientSecret'));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Basic $basic')
      ..contentType = ContentType('application', 'x-www-form-urlencoded')
      ..set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    request.write('grant_type=client_credentials');

    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    if (body is! Map || body['access_token'] is! String) {
      throw const HttpException('Orange token response had no access_token');
    }

    _token = body['access_token'] as String;
    _tokenExpiresAt = _clock.now().add(
      Duration(seconds: int.tryParse('${body['expires_in']}') ?? 3000),
    );
    return _token!;
  }

  Future<_Response> _send(String path, Map<String, Object?> payload) async {
    final token = await _accessToken();
    final request = await _http.postUrl(baseUrl.resolve(path));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    request.write(jsonEncode(payload));

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return _Response(response.statusCode, _decode(text));
  }

  static Map<String, Object?> _decode(String text) {
    if (text.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : {'body': decoded};
    } on FormatException {
      // Kept verbatim rather than dropped: an HTML error page from a proxy is
      // exactly the thing somebody needs to see six weeks later.
      return {'body': text};
    }
  }

  void close() => _http.close(force: true);
}

final class _Response {
  const _Response(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}
