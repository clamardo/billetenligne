import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// One week's statement, as both consoles read it (`04-payments.md` §6.2).
///
/// **Every line item travels, including the cash ones that are never paid
/// out.** "Where is my cash money?" is the first question an operator asks
/// about a statement, every time, and a statement that omitted the cash sales
/// would generate the phone call it exists to prevent.
final class PayoutRunDto {
  const PayoutRunDto({
    required this.id,
    required this.operatorId,
    required this.periodStart,
    required this.periodEnd,
    required this.onlineSalesCount,
    required this.onlineGross,
    required this.cashSalesCount,
    required this.cashGross,
    required this.commission,
    required this.serviceFees,
    required this.refunds,
    required this.payable,
    required this.tills,
    required this.net,
    required this.state,
    required this.preparedAt,
    this.operatorName,
    this.approvedAt,
    this.paidAt,
    this.destination,
    this.reference,
  });

  final String id;
  final String operatorId;
  final String? operatorName;

  /// Half-open, `[periodStart, periodEnd)`.
  final DateTime periodStart;
  final DateTime periodEnd;

  final int onlineSalesCount;
  final Money onlineGross;
  final int cashSalesCount;
  final Money cashGross;
  final Money commission;
  final Money serviceFees;
  final Money refunds;

  /// What the ledger says we owe, and what is in the operator's drawers. Both
  /// travel, because the net is the difference and a reader who cannot see
  /// both halves cannot check it.
  final Money payable;
  final Money tills;

  /// Signed. Negative means the operator owes us — a week of nothing but cash
  /// sales — and that is a statement rather than a transfer.
  final Money net;

  /// `draft` · `approved` · `paid` · `void`.
  final String state;

  final DateTime preparedAt;
  final DateTime? approvedAt;
  final DateTime? paidAt;
  final String? destination;
  final String? reference;

  bool get isPayable => net.minor > 0;
  bool get operatorOwesUs => net.minor < 0;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'operatorId': operatorId,
    'operatorName': operatorName,
    'periodStart': Wire.instant(periodStart),
    'periodEnd': Wire.instant(periodEnd),
    'onlineSalesCount': onlineSalesCount,
    'onlineGross': Wire.money(onlineGross),
    'cashSalesCount': cashSalesCount,
    'cashGross': Wire.money(cashGross),
    'commission': Wire.money(commission),
    'serviceFees': Wire.money(serviceFees),
    'refunds': Wire.money(refunds),
    'payable': Wire.money(payable),
    'tills': Wire.money(tills),
    'net': Wire.money(net),
    'state': state,
    'preparedAt': Wire.instant(preparedAt),
    'approvedAt': approvedAt == null ? null : Wire.instant(approvedAt!),
    'paidAt': paidAt == null ? null : Wire.instant(paidAt!),
    'destination': destination,
    'reference': reference,
  });

  factory PayoutRunDto.fromJson(Map<String, Object?> json) => PayoutRunDto(
    id: Wire.requireString(json['id'], 'id'),
    operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
    operatorName: json['operatorName'] as String?,
    periodStart: Wire.readInstant(json['periodStart'], field: 'periodStart'),
    periodEnd: Wire.readInstant(json['periodEnd'], field: 'periodEnd'),
    onlineSalesCount: Wire.requireInt(
      json['onlineSalesCount'],
      'onlineSalesCount',
    ),
    onlineGross: Wire.readMoney(json['onlineGross'], field: 'onlineGross'),
    cashSalesCount: Wire.requireInt(json['cashSalesCount'], 'cashSalesCount'),
    cashGross: Wire.readMoney(json['cashGross'], field: 'cashGross'),
    commission: Wire.readMoney(json['commission'], field: 'commission'),
    serviceFees: Wire.readMoney(json['serviceFees'], field: 'serviceFees'),
    refunds: Wire.readMoney(json['refunds'], field: 'refunds'),
    payable: Wire.readMoney(json['payable'], field: 'payable'),
    tills: Wire.readMoney(json['tills'], field: 'tills'),
    net: Wire.readMoney(json['net'], field: 'net'),
    state: Wire.requireString(json['state'], 'state'),
    preparedAt: Wire.readInstant(json['preparedAt'], field: 'preparedAt'),
    approvedAt: Wire.readInstantOrNull(json['approvedAt']),
    paidAt: Wire.readInstantOrNull(json['paidAt']),
    destination: json['destination'] as String?,
    reference: json['reference'] as String?,
  );
}

/// Preparing a run for one operator over one window.
final class PreparePayoutRequest {
  const PreparePayoutRequest({
    required this.operatorId,
    required this.periodStart,
    required this.periodEnd,
  });

  final String operatorId;
  final DateTime periodStart;
  final DateTime periodEnd;

  Map<String, Object?> toJson() => {
    'operatorId': operatorId,
    'periodStart': Wire.instant(periodStart),
    'periodEnd': Wire.instant(periodEnd),
  };

  factory PreparePayoutRequest.fromJson(Map<String, Object?> json) =>
      PreparePayoutRequest(
        operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
        periodStart: Wire.readInstant(
          json['periodStart'],
          field: 'periodStart',
        ),
        periodEnd: Wire.readInstant(json['periodEnd'], field: 'periodEnd'),
      );
}

/// Approving a prepared run, or releasing an approved one.
///
/// One request type for both, because the decision they carry is the same
/// shape: a verb, and — for a release — the reference the money went out
/// under. A release with no reference is a transfer nobody can find in a
/// bank statement afterwards.
final class PayoutDecisionRequest {
  const PayoutDecisionRequest({
    required this.decision,
    this.reference,
    this.destination,
  });

  /// `approve` or `release`.
  final String decision;

  final String? reference;
  final String? destination;

  Map<String, Object?> toJson() => Wire.compact({
    'decision': decision,
    'reference': reference,
    'destination': destination,
  });

  factory PayoutDecisionRequest.fromJson(Map<String, Object?> json) =>
      PayoutDecisionRequest(
        decision: Wire.requireString(json['decision'], 'decision'),
        reference: json['reference'] as String?,
        destination: json['destination'] as String?,
      );
}
