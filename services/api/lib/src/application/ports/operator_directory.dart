import 'package:bel_domain/bel_domain.dart';

/// The commercial facts about one operator that a use case has to know.
///
/// Small on purpose, and separate from `OperatorConsole`: that port is what an
/// operator's *staff* do to their own fleet, this one is what the *platform*
/// knows about the agreement it has with them. The console is a big interface
/// serving a big screen; this is one number that decides what we keep from a
/// fare, and it wants no company.
abstract interface class OperatorDirectory {
  /// The negotiated commission for one operator.
  ///
  /// Read at the moment money moves rather than snapshotted onto the booking,
  /// and that is a decision: nothing is owed until the fare is captured, so
  /// the agreement in force when we take the money is the one that governs. A
  /// rate renegotiated on Tuesday does not reprice Monday's *settled* sale,
  /// because that posting is already written and a ledger is not rewritten —
  /// it only governs what settles after it.
  ///
  /// Null when there is no such operator, which the caller must treat as "do
  /// not guess a rate" rather than "assume the default".
  Future<CommissionTerm?> commissionFor(String operatorId);
}
