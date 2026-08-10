import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// A payment in limbo, as the reconciliation queue lists it.
///
/// `indeterminate` is a first-class state, not an error: the rail went silent
/// and **the money may have moved**. Everything on this row exists so that
/// one person can decide which — the amount, the number it was pulled from,
/// what the rail called it, and how to reach the traveller who is in the dark
/// (ADR-0005).
final class UnresolvedPaymentDto {
  const UnresolvedPaymentDto({
    required this.intentId,
    required this.state,
    required this.railId,
    required this.amount,
    required this.payerMsisdn,
    required this.createdAt,
    required this.bookingId,
    required this.bookingRef,
    required this.bookingState,
    required this.operatorId,
    required this.operatorName,
    this.pollAttempts = 0,
    this.lastPolledAt,
    this.railTransactionId,
    this.travellerPhone,
    this.travellerEmail,
    this.departsAt,
    this.originCity,
    this.destinationCity,
  });

  final String intentId;
  final String state;
  final String railId;
  final Money amount;
  final String payerMsisdn;
  final DateTime createdAt;

  final String bookingId;
  final String bookingRef;
  final String bookingState;

  final String operatorId;
  final String operatorName;

  final int pollAttempts;
  final DateTime? lastPolledAt;

  /// What the rail called it. The reference somebody reads down a phone line
  /// to a telco's support desk, which is how most of these actually resolve.
  final String? railTransactionId;

  final String? travellerPhone;
  final String? travellerEmail;

  final DateTime? departsAt;
  final String? originCity;
  final String? destinationCity;

  Map<String, Object?> toJson() => Wire.compact({
    'intentId': intentId,
    'state': state,
    'railId': railId,
    'amount': Wire.money(amount),
    'payerMsisdn': payerMsisdn,
    'createdAt': Wire.instant(createdAt),
    'bookingId': bookingId,
    'bookingRef': bookingRef,
    'bookingState': bookingState,
    'operatorId': operatorId,
    'operatorName': operatorName,
    'pollAttempts': pollAttempts,
    'lastPolledAt': lastPolledAt == null ? null : Wire.instant(lastPolledAt!),
    'railTransactionId': railTransactionId,
    'travellerPhone': travellerPhone,
    'travellerEmail': travellerEmail,
    'departsAt': departsAt == null ? null : Wire.instant(departsAt!),
    'originCity': originCity,
    'destinationCity': destinationCity,
  });

  factory UnresolvedPaymentDto.fromJson(Map<String, Object?> json) =>
      UnresolvedPaymentDto(
        intentId: Wire.requireString(json['intentId'], 'intentId'),
        state: Wire.requireString(json['state'], 'state'),
        railId: Wire.requireString(json['railId'], 'railId'),
        amount: Wire.readMoney(json['amount'], field: 'amount'),
        payerMsisdn: Wire.requireString(json['payerMsisdn'], 'payerMsisdn'),
        createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
        bookingId: Wire.requireString(json['bookingId'], 'bookingId'),
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        bookingState: Wire.requireString(json['bookingState'], 'bookingState'),
        operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
        operatorName: Wire.requireString(json['operatorName'], 'operatorName'),
        pollAttempts: (json['pollAttempts'] as int?) ?? 0,
        lastPolledAt: Wire.readInstantOrNull(
          json['lastPolledAt'],
          field: 'lastPolledAt',
        ),
        railTransactionId: json['railTransactionId'] as String?,
        travellerPhone: json['travellerPhone'] as String?,
        travellerEmail: json['travellerEmail'] as String?,
        departsAt: Wire.readInstantOrNull(
          json['departsAt'],
          field: 'departsAt',
        ),
        originCity: json['originCity'] as String?,
        destinationCity: json['destinationCity'] as String?,
      );
}

/// What a human decided about a payment the network never settled.
///
/// Three outcomes, and `reask` is deliberately one of them: most of these
/// resolve by asking the rail once more after it has caught up, and a queue
/// whose only tools are "declare it paid" and "declare it lost" invites
/// somebody to guess when they could have known.
final class ResolvePaymentRequest {
  const ResolvePaymentRequest({
    required this.outcome,
    required this.reason,
    this.failureCode,
  });

  /// `reask` | `captured` | `failed`.
  final String outcome;

  /// Mandatory, and written into `payment_events` with the actor. This is the
  /// row that settles a dispute six weeks later, and "somebody marked it
  /// paid" is not an answer.
  final String reason;

  /// Optional on `failed`, so a resolution can carry the same taxonomy the
  /// rails do rather than collapsing every one into "it did not work".
  final String? failureCode;

  Map<String, Object?> toJson() => Wire.compact({
    'outcome': outcome,
    'reason': reason,
    'failureCode': failureCode,
  });

  factory ResolvePaymentRequest.fromJson(Map<String, Object?> json) =>
      ResolvePaymentRequest(
        outcome: Wire.requireString(json['outcome'], 'outcome'),
        reason: Wire.requireString(json['reason'], 'reason'),
        failureCode: json['failureCode'] as String?,
      );
}
