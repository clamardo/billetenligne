import 'package:bel_domain/bel_domain.dart';

/// A statement, and where it has got to.
final class PayoutRun {
  const PayoutRun({
    required this.id,
    required this.statement,
    required this.state,
    required this.preparedAt,
    this.operatorName,
    this.approvedAt,
    this.paidAt,
    this.destination,
    this.reference,
  });

  final String id;
  final PayoutStatement statement;

  /// `draft` · `approved` · `paid` · `void`.
  ///
  /// Approval and payment are separate states written at different times by
  /// different people. A run that was approved and never paid is then a
  /// visible row rather than an absence — the difference between chasing it
  /// and discovering it.
  final String state;

  final DateTime preparedAt;
  final String? operatorName;
  final DateTime? approvedAt;
  final DateTime? paidAt;
  final String? destination;
  final String? reference;

  bool get isPending => state == 'draft' || state == 'approved';
}

/// Why a payout could not be prepared, approved or released.
sealed class PayoutRefusal {
  const PayoutRefusal();
  String get code;
}

/// No such operator, or no such run.
final class UnknownPayout extends PayoutRefusal {
  const UnknownPayout();
  @override
  String get code => 'payout.unknown';
}

/// This week already has a run that is not void. The one mistake here that
/// cannot be undone with an UPDATE is paying the same week twice.
final class PeriodAlreadyRun extends PayoutRefusal {
  const PeriodAlreadyRun();
  @override
  String get code => 'payout.period_already_run';
}

/// The run is not in a state that allows what was asked — approving one that
/// is already paid, releasing one nobody has approved.
final class WrongPayoutState extends PayoutRefusal {
  const WrongPayoutState(this.state);
  final String state;
  @override
  String get code => 'payout.wrong_state';
}

/// The same person cannot approve their own preparation.
///
/// Two-person control (ADR-0011), enforced on the *people* rather than only
/// on the roles: two super-admins is a control, one super-admin pressing both
/// buttons is a formality.
final class NeedsASecondPerson extends PayoutRefusal {
  const NeedsASecondPerson();
  @override
  String get code => 'payout.needs_a_second_person';
}

/// The domain refused the movement — nothing to pay, or money owed the other
/// way. Carried rather than flattened, because "they owe us 54 000" is a
/// different conversation from "there is nothing to send".
final class PayoutRefused extends PayoutRefusal {
  const PayoutRefused(this.failure);
  final DomainFailure failure;
  @override
  String get code => failure.code;
}

/// The payout run (`04-payments.md` §6.2).
///
/// Three verbs on purpose, and the gap between them is the control:
/// **prepare** writes what the period contained and what the ledger says is
/// owed; **approve** is a second person agreeing to it; **release** is the
/// only one that moves money, and it posts the ledger transaction in the same
/// breath as it marks the run paid.
abstract interface class PayoutDesk {
  /// Computes the statement for `[from, to)` and records it as a draft.
  ///
  /// The line items describe the window. **The amount does not**: it is the
  /// balance of `payable:operator:<id>` less the operator's tills at this
  /// moment, because a payout that summed a period would drift from the
  /// ledger the first time anything landed a day late.
  Future<Result<PayoutRun, PayoutRefusal>> prepare({
    required String operatorId,
    required DateTime from,
    required DateTime to,
    required String actorUserId,
  });

  Future<Result<PayoutRun, PayoutRefusal>> approve({
    required String runId,
    required String actorUserId,
  });

  /// Posts the movement and marks the run paid, in one transaction.
  Future<Result<PayoutRun, PayoutRefusal>> release({
    required String runId,
    required String actorUserId,
    required String reference,
    String? destination,
  });

  /// The platform's work queue: everything prepared and not yet paid, oldest
  /// first, across every operator.
  Future<List<PayoutRun>> pending({required String actorUserId});

  /// One operator's own statements, newest first. What the console shows.
  Future<List<PayoutRun>> statementsFor(String operatorId);
}
