import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// Start a payment against a hold.
///
/// Requires the `Idempotency-Key` header. The server stores `(key -> intent)`
/// for 24 h, so a duplicate tap can never create a second charge — the single
/// most important safety property in this API (ADR-0005 rule 2).
final class CreatePaymentRequest {
  const CreatePaymentRequest({
    required this.holdId,
    required this.railId,
    this.msisdn,
    this.returnUrl,
  });

  final String holdId;

  /// e.g. `cg.airtel_money`. A string, so adding a country's rails needs no
  /// change to this type.
  final String railId;

  /// The wallet to debit. Editable by the traveller and often not their own
  /// account number — people pay from a family member's wallet routinely, and
  /// blocking that would cost real transactions.
  final String? msisdn;

  /// Card only: where the PSP sends the browser after 3-D Secure. The result
  /// is confirmed server-side regardless — never from the redirect URL.
  final String? returnUrl;

  Map<String, Object?> toJson() => Wire.compact({
    'holdId': holdId,
    'railId': railId,
    'msisdn': msisdn,
    'returnUrl': returnUrl,
  });

  factory CreatePaymentRequest.fromJson(Map<String, Object?> json) =>
      CreatePaymentRequest(
        holdId: Wire.requireString(json['holdId'], 'holdId'),
        railId: Wire.requireString(json['railId'], 'railId'),
        msisdn: json['msisdn'] as String?,
        returnUrl: json['returnUrl'] as String?,
      );
}

/// A payment attempt, as the waiting screen sees it.
final class PaymentIntentDto {
  const PaymentIntentDto({
    required this.id,
    required this.state,
    required this.railId,
    required this.amount,
    required this.createdAt,
    this.failureCode,
    this.expiresAt,
    this.ussdCode,
    this.redirectUrl,
    this.bookingRef,
    this.pollAfterSeconds,
  });

  final String id;

  /// `pending`, `captured`, `indeterminate`, … — matches [PaymentState.name].
  final String state;

  final String railId;
  final Money amount;
  final DateTime createdAt;

  /// Present only in a failed state, and it is what selects the message and
  /// the recovery the traveller is offered. Twelve codes, twelve sentences.
  final String? failureCode;

  /// End of the payment window, so the waiting screen counts down honestly.
  final DateTime? expiresAt;

  /// Shown when the push prompt does not arrive. Prompts genuinely fail;
  /// giving the user a manual path beats a spinner.
  final String? ussdCode;

  final String? redirectUrl;

  /// Set once the ticket exists.
  final String? bookingRef;

  /// How long the client should wait before polling again. Server-driven so
  /// the backoff schedule can be tuned without an app release.
  final int? pollAfterSeconds;

  bool get isSettled => state == PaymentState.captured.name;
  bool get isInFlight =>
      state == PaymentState.pending.name ||
      state == PaymentState.authorized.name ||
      state == PaymentState.indeterminate.name;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'state': state,
    'railId': railId,
    'amount': Wire.money(amount),
    'createdAt': Wire.instant(createdAt),
    'failureCode': failureCode,
    'expiresAt': expiresAt == null ? null : Wire.instant(expiresAt!),
    'ussdCode': ussdCode,
    'redirectUrl': redirectUrl,
    'bookingRef': bookingRef,
    'pollAfterSeconds': pollAfterSeconds,
  });

  factory PaymentIntentDto.fromJson(Map<String, Object?> json) =>
      PaymentIntentDto(
        id: Wire.requireString(json['id'], 'id'),
        state: Wire.requireString(json['state'], 'state'),
        railId: Wire.requireString(json['railId'], 'railId'),
        amount: Wire.readMoney(json['amount'], field: 'amount'),
        createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
        failureCode: json['failureCode'] as String?,
        expiresAt: Wire.readInstantOrNull(
          json['expiresAt'],
          field: 'expiresAt',
        ),
        ussdCode: json['ussdCode'] as String?,
        redirectUrl: json['redirectUrl'] as String?,
        bookingRef: json['bookingRef'] as String?,
        pollAfterSeconds: json['pollAfterSeconds'] as int?,
      );

  factory PaymentIntentDto.fromDomain(
    PaymentIntent intent, {
    String? ussdCode,
    DateTime? expiresAt,
    String? bookingRef,
  }) => PaymentIntentDto(
    id: intent.id,
    state: intent.state.name,
    railId: intent.railId,
    amount: intent.amount,
    createdAt: intent.createdAt,
    failureCode: intent.failureCode?.wire,
    expiresAt: expiresAt,
    ussdCode: ussdCode,
    bookingRef: bookingRef,
    pollAfterSeconds: intent.state.isInFlight
        ? intent.nextPollDelay.inSeconds
        : null,
  );
}

/// What a traveller will actually receive, and when.
///
/// Produced by `quoteRefund()` in the shared domain — the same function the
/// server executes with. The number on the confirmation screen and the number
/// that arrives are the same number (ADR-0004).
final class RefundQuoteDto {
  const RefundQuoteDto({
    required this.bookingRef,
    required this.paid,
    required this.refundable,
    required this.retained,
    required this.rateBps,
    required this.destination,
    required this.processingHours,
    required this.involuntary,
    this.serviceFeeRefundable = false,
    this.policySummaryKey,
  });

  final String bookingRef;
  final Money paid;
  final Money refundable;
  final Money retained;

  /// 10000 = 100%. Integer basis points, so nothing drifts in floating point.
  final int rateBps;

  /// `source`, `agencyCash`, `creditNote` or `travellerChoice`. When it is
  /// `agencyCash` the flow changes shape — and the app must have said so
  /// before purchase, not at cancellation (ADR-0015 rule 5).
  final String destination;

  /// What we promise the traveller. A window, never an instant: mobile money
  /// disbursement is a different API from collection and often slower.
  final int processingHours;

  /// Operator-caused. Bypasses the configured policy entirely — the platform
  /// floor. An operator cannot configure its way out of its own breakdown.
  final bool involuntary;

  final bool serviceFeeRefundable;
  final String? policySummaryKey;

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'paid': Wire.money(paid),
    'refundable': Wire.money(refundable),
    'retained': Wire.money(retained),
    'rateBps': rateBps,
    'destination': destination,
    'processingHours': processingHours,
    'involuntary': involuntary,
    'serviceFeeRefundable': serviceFeeRefundable,
    'policySummaryKey': policySummaryKey,
  });

  factory RefundQuoteDto.fromJson(Map<String, Object?> json) => RefundQuoteDto(
    bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
    paid: Wire.readMoney(json['paid'], field: 'paid'),
    refundable: Wire.readMoney(json['refundable'], field: 'refundable'),
    retained: Wire.readMoney(json['retained'], field: 'retained'),
    rateBps: Wire.requireInt(json['rateBps'], 'rateBps'),
    destination: Wire.requireString(json['destination'], 'destination'),
    processingHours: Wire.requireInt(
      json['processingHours'],
      'processingHours',
    ),
    involuntary: json['involuntary'] as bool? ?? false,
    serviceFeeRefundable: json['serviceFeeRefundable'] as bool? ?? false,
    policySummaryKey: json['policySummaryKey'] as String?,
  );

  factory RefundQuoteDto.fromDomain(
    RefundQuote q, {
    required String bookingRef,
    String? policySummaryKey,
  }) => RefundQuoteDto(
    bookingRef: bookingRef,
    paid: q.faceValue + q.serviceFee,
    refundable: q.refundable,
    retained: q.retained,
    rateBps: q.rateBps,
    destination: q.destination.name,
    processingHours: q.processingWindow.inHours,
    involuntary: q.involuntary,
    policySummaryKey: policySummaryKey,
  );
}
