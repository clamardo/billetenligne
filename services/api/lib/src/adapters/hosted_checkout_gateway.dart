import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/payment_gateway.dart';

/// A card, entered on somebody else's page.
///
/// **Written against no merchant account.** There is no card PSP contract for
/// this market yet, so what this adapter targets is the shape every hosted
/// checkout in the region shares — CinetPay, PayDunya, Flutterwave, Stripe
/// Checkout all do the same three things — rather than one vendor's field
/// names. Swapping in a real one is [_body] and [_statusOf]; everything above
/// this file, including the state machine, the poller and the ledger, is
/// already right. `SandboxCheckoutGateway` below is what the funnel runs on
/// until a contract exists, and it is deliberately in the same file so the
/// two cannot drift.
///
/// **The card number never touches this system.** That is the whole reason to
/// use a hosted page rather than collecting a PAN ourselves: it moves the
/// entire PCI surface to the PSP, and there is no version of "just this once"
/// that is worth taking it back.
///
/// Three things differ from a mobile-money rail, and each of them is why
/// `pushesToHandset` exists rather than a check on the rail id:
///
///   * there is **no wallet number** — the money comes from a card this
///     system never sees;
///   * the first answer carries a **URL**, not a promise that a handset is
///     ringing;
///   * the traveller comes back through a **return URL**, which is a hint
///     that the wait is over and never authority that money moved. The
///     capture is confirmed by re-querying, exactly as a callback is
///     (ADR-0005 rule 4). A return URL is a browser redirect and anybody can
///     type one.
final class HostedCheckoutGateway implements PaymentGateway {
  HostedCheckoutGateway({
    required this.baseUrl,
    required this.apiKey,
    required this.siteId,
    required this.callbackUrl,
    this.railId = 'cg.card',
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final Uri baseUrl;
  final String apiKey;

  /// Which merchant account the money lands in. Every PSP in this region
  /// keys on something like it, and getting it wrong is a payment that
  /// succeeds into somebody else's balance.
  final String siteId;

  /// Where the PSP tells us, server to server. Untrusted like every other
  /// callback: it wakes the re-query, it does not decide anything.
  final String callbackUrl;

  @override
  final String railId;

  final HttpClient _http;

  /// A card is typed on a page somewhere else. Nothing rings.
  @override
  bool get pushesToHandset => false;

  @override
  Future<PaymentOutcome> requestPayment(PaymentRequest request) async {
    try {
      final response = await _post('/v2/payment', _body(request));

      final url = response.body['checkout_url'] ?? response.body['payment_url'];
      if (response.status == HttpStatus.ok && url is String && url.isNotEmpty) {
        // Pending, not authorized: the page has been created and nobody has
        // typed a card into it. Everything else in this system already knows
        // what to do with a pending intent.
        return PaymentOutcome(
          state: PaymentState.pending,
          checkoutUrl: url,
          railTransactionId: response.body['transaction_id'] as String?,
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
    try {
      final response = await _post('/v2/payment/check', {
        'apikey': apiKey,
        'site_id': siteId,
        'transaction_id': railTransactionId ?? intentId,
      });
      return _statusOf(response);
    } on SocketException {
      return PaymentOutcome.unknown;
    } on HttpException {
      return PaymentOutcome.unknown;
    }
  }

  /// What a checkout is asked for. One of the two methods a real contract
  /// changes.
  Map<String, Object?> _body(PaymentRequest request) => {
    'apikey': apiKey,
    'site_id': siteId,
    // Ours, and the handle every later query uses — the same discipline the
    // MTN adapter keeps with `X-Reference-Id`.
    'transaction_id': request.intentId,
    'amount': _amount(request.amount),
    'currency': request.amount.currency.code,
    'description': request.description,
    'notify_url': callbackUrl,
    // Absent would mean a traveller stranded on a PSP's "thank you" page with
    // no way back into the app, which is indistinguishable from a failure to
    // somebody standing in a queue.
    'return_url': request.returnUrl,
  };

  /// The PSP's vocabulary, mapped onto ours. The other method a real contract
  /// changes.
  ///
  /// An **unrecognised status is pending**, never failed. PSPs add values,
  /// and treating one we have not seen as a failure refuses money that has
  /// already moved.
  PaymentOutcome _statusOf(_Response response) {
    final status = '${response.body['status'] ?? ''}'.toUpperCase();
    return switch (status) {
      'ACCEPTED' || 'SUCCESS' || 'COMPLETED' => PaymentOutcome(
        state: PaymentState.captured,
        railTransactionId: response.body['transaction_id'] as String?,
        raw: response.body,
      ),
      'REFUSED' || 'FAILED' || 'DECLINED' => PaymentOutcome(
        state: PaymentState.failed,
        failureCode: _failureCode('${response.body['code'] ?? ''}'),
        raw: response.body,
      ),
      'CANCELLED' || 'EXPIRED' => PaymentOutcome(
        state: PaymentState.failed,
        failureCode: PaymentFailureCode.userDeclined,
        raw: response.body,
      ),
      _ => PaymentOutcome(state: PaymentState.pending, raw: response.body),
    };
  }

  /// A card decline is not one thing, and every one of these has its own
  /// sentence and its own recovery in the app (`04-payments.md` §5).
  static PaymentFailureCode _failureCode(String code) =>
      switch (code.toUpperCase()) {
        'INSUFFICIENT_FUNDS' ||
        'INSUFFICIENT_BALANCE' => PaymentFailureCode.insufficientFunds,
        'DO_NOT_HONOR' || 'CARD_DECLINED' => PaymentFailureCode.userDeclined,
        'EXPIRED_CARD' ||
        'RESTRICTED_CARD' ||
        'LOST_CARD' ||
        'STOLEN_CARD' => PaymentFailureCode.subscriberBarred,
        'LIMIT_EXCEEDED' ||
        'EXCEEDS_WITHDRAWAL_LIMIT' => PaymentFailureCode.limitExceeded,
        // "Try a different card" is the honest instruction for a decline
        // nobody explained, and it is what `userDeclined` renders.
        _ => PaymentFailureCode.userDeclined,
      };

  /// Whole units. XAF has no minor unit, so 9 300 francs is `9300`.
  static num _amount(Money amount) {
    if (amount.currency.exponent == 0) return amount.minor;
    var divisor = 1;
    for (var i = 0; i < amount.currency.exponent; i++) {
      divisor *= 10;
    }
    return amount.minor / divisor;
  }

  Future<_Response> _post(String path, Map<String, Object?> body) async {
    final request = await _http.postUrl(baseUrl.resolve(path));
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
    request.write(jsonEncode(body));

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return _Response(response.statusCode, _decode(text));
  }

  static Map<String, Object?> _decode(String text) {
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : {'body': decoded};
    } on FormatException {
      // Kept verbatim rather than dropped: an HTML error page from a proxy is
      // exactly the thing somebody needs to see six weeks later.
      return {'body': text};
    }
  }
}

final class _Response {
  const _Response(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}

/// A card rail with no PSP behind it.
///
/// The counterpart of `FakePaymentGateway` for hosted checkout, and it exists
/// for the same two reasons: ADR-0005 makes the pathologies a release gate,
/// and a fresh clone must be able to walk the whole funnel with no
/// credentials. It mints a URL that goes nowhere real and answers whatever it
/// is told to.
///
/// **It is not a card payment.** Nothing is charged, and the only reason it
/// answers `captured` is that a test asked it to.
final class SandboxCheckoutGateway implements PaymentGateway {
  SandboxCheckoutGateway({
    this.railId = 'cg.card',
    this.checkoutBase = 'https://checkout.invalid/pay',
  });

  @override
  final String railId;

  /// Where the minted URL points. `.invalid` by RFC 2606, so a URL that
  /// escapes into a real build cannot resolve to somebody's page.
  final String checkoutBase;

  @override
  bool get pushesToHandset => false;

  /// What the next request answers. Pending with a URL is the ordinary case.
  PaymentOutcome? onRequest;

  /// Scripted answers, so a test can watch the poller converge across a
  /// traveller typing a card number.
  final List<PaymentOutcome> statusScript = [];

  final List<PaymentRequest> requests = [];
  final List<String> queried = [];

  @override
  Future<PaymentOutcome> requestPayment(PaymentRequest request) async {
    requests.add(request);
    if (onRequest case final scripted?) return scripted;

    return PaymentOutcome(
      state: PaymentState.pending,
      checkoutUrl: '$checkoutBase/${request.intentId}',
      railTransactionId: 'sandbox-${request.intentId}',
      raw: {'sandbox': true, 'returnUrl': request.returnUrl},
    );
  }

  @override
  Future<PaymentOutcome> queryStatus({
    required String intentId,
    String? railTransactionId,
  }) async {
    queried.add(intentId);
    if (statusScript.isEmpty) return PaymentOutcome.unknown;
    return statusScript.removeAt(0);
  }
}
