import 'package:bel_domain/bel_domain.dart';

/// One operator's platform subscription fee for one calendar month
/// (`04-payments.md` §6.2 note).
final class SubscriptionCharge {
  const SubscriptionCharge({
    required this.id,
    required this.operatorId,
    required this.periodStart,
    required this.periodEnd,
    required this.amount,
    required this.status,
    required this.createdAt,
    this.paidAt,
  });

  final String id;
  final String operatorId;

  /// Half-open, `[periodStart, periodEnd)`, like a payout period.
  final DateTime periodStart;
  final DateTime periodEnd;

  final Money amount;

  /// `due` | `paid`.
  final String status;

  final DateTime createdAt;
  final DateTime? paidAt;

  bool get isPaid => status == 'paid';
}

/// Why a billing action was refused.
sealed class BillingRefusal {
  const BillingRefusal();
  String get code;
}

final class UnknownBillingOperator extends BillingRefusal {
  const UnknownBillingOperator();
  @override
  String get code => 'billing.unknown_operator';
}

final class UnknownPaymentType extends BillingRefusal {
  const UnknownPaymentType(this.paymentType);
  final String paymentType;
  @override
  String get code => 'billing.unknown_payment_type';
}

/// The platform subscription fee (`04-payments.md` §6.2 note) — a flat
/// monthly charge, entirely separate from the payout run. An operator reads
/// what it owes and chooses how to pay; it does not get to mark its own
/// charge paid, the same asymmetry `PayoutDesk` draws around a payout.
abstract interface class BillingDesk {
  /// This calendar month's charge for [operatorId], creating it — and its
  /// accrual ledger entries — the first time anybody asks this month. One
  /// flat tier at launch, so there is no plan to choose between.
  Future<SubscriptionCharge> currentCharge(String operatorId);

  /// Which rail this operator currently intends to pay with — `card` or
  /// `bank_transfer`, defaulting to `bank_transfer` until they choose.
  ///
  /// Not stored on the charge itself: there is no automatic capture behind
  /// either rail yet, so a payment type is a live preference the screen asks
  /// about fresh every time, not a fact an already-created, still-`due`
  /// charge needs to remember.
  Future<String> paymentType(String operatorId);

  /// Changes which rail this operator intends to pay with.
  ///
  /// A preference, not a transaction — no money moves and no ledger entry is
  /// written.
  Future<Result<void, BillingRefusal>> setPaymentType({
    required String operatorId,
    required String paymentType,
    required String actorUserId,
  });
}
