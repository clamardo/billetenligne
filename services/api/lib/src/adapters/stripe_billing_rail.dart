import 'dart:convert';
import 'dart:io';

import 'package:bel_domain/bel_domain.dart';

import '../application/ports/platform_billing_rail.dart';

/// A card, entered on Stripe's own Checkout page — for the platform fee, not
/// a ticket.
///
/// **Written against no Stripe account.** There is not one yet (the whole
/// reason this class exists rather than a real integration going straight
/// in), so [secretKey] is empty on every deployment today and
/// [instructionsFor] answers `available: false` without attempting a call.
/// The request this builds is the real Checkout Sessions shape Stripe's REST
/// API expects, not a guess at one — the day a key is set, this is the one
/// line that changes, exactly the contract `hosted_checkout_gateway.dart`
/// keeps for the ticket-payment rails.
///
/// Money never touches this system either way: Checkout is Stripe's own
/// hosted page, so this stays out of PCI scope the same way a ticket paid by
/// card does (`04-payments.md` §4.3).
final class StripeBillingRail implements PlatformBillingRail {
  StripeBillingRail({
    required this.secretKey,
    required this.successUrl,
    required this.cancelUrl,
    Uri? baseUrl,
    HttpClient? httpClient,
  }) : baseUrl = baseUrl ?? Uri.parse('https://api.stripe.com'),
       _http = httpClient ?? HttpClient();

  /// Empty on every deployment until a real Stripe account exists. Checked
  /// before anything is sent — a request signed with an empty key is not a
  /// call Stripe would answer, it is a stack trace with extra steps.
  final String secretKey;

  final Uri successUrl;
  final Uri cancelUrl;
  final Uri baseUrl;

  final HttpClient _http;

  @override
  String get paymentType => 'card';

  @override
  Future<PlatformBillingInstruction> instructionsFor({
    required String operatorId,
    required Money amountDue,
    required String reference,
  }) async {
    // No English or French sentence is built here: "why is this unavailable"
    // is copy, and copy belongs on the console's own i18n keys, not
    // travelling over the wire from an adapter that does not know what
    // language is asking.
    if (secretKey.isEmpty) {
      return const PlatformBillingInstruction(available: false);
    }

    try {
      final response = await _createSession(
        operatorId: operatorId,
        amountDue: amountDue,
        reference: reference,
      );

      final url = response.body['url'];
      if (response.status == HttpStatus.ok && url is String && url.isNotEmpty) {
        return PlatformBillingInstruction(available: true, checkoutUrl: url);
      }
      return const PlatformBillingInstruction(available: false);
    } on SocketException {
      return const PlatformBillingInstruction(available: false);
    } on HttpException {
      return const PlatformBillingInstruction(available: false);
    }
  }

  /// `POST /v1/checkout/sessions` — Stripe's real shape: form-encoded, not
  /// JSON, and nested fields addressed with bracket notation. Getting this
  /// wrong is invisible until a real key is set, which is exactly why it is
  /// written against the documented contract now rather than left as a stub.
  Future<_Response> _createSession({
    required String operatorId,
    required Money amountDue,
    required String reference,
  }) async {
    final request = await _http.postUrl(
      baseUrl.resolve('/v1/checkout/sessions'),
    );
    request.headers
      ..set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$secretKey:'))}',
      )
      ..contentType = ContentType('application', 'x-www-form-urlencoded');

    request.write(
      Uri(
        queryParameters: {
          'mode': 'payment',
          'success_url': successUrl.toString(),
          'cancel_url': cancelUrl.toString(),
          'client_reference_id': reference,
          'metadata[operator_id]': operatorId,
          'line_items[0][quantity]': '1',
          'line_items[0][price_data][currency]': amountDue.currency.code
              .toLowerCase(),
          'line_items[0][price_data][unit_amount]': '${amountDue.minor}',
          'line_items[0][price_data][product_data][name]':
              'BilletEnLigne — abonnement plateforme',
        },
      ).query,
    );

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
      return {'body': text};
    }
  }
}

final class _Response {
  const _Response(this.status, this.body);
  final int status;
  final Map<String, Object?> body;
}
