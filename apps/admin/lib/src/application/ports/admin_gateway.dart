import 'package:bel_contracts/bel_contracts.dart';

/// Everything the back office needs from the outside world.
///
/// One port, like the console's `ConsoleGateway` and for the same reason:
/// these calls are one conversation. A queue leads to one operator's file
/// leads to a decision, and the reconciliation queue is the same person's
/// other half-hour of the day.
///
/// **Every method takes a reason.** Not a parameter that happens to be
/// threaded through — the admin surface refuses a mutation without one, and
/// records it against the actor on every read (ADR-0011). Putting it in the
/// port's signature is what stops a screen from being written that has no
/// place to type it.
abstract interface class AdminGateway {
  /// Who is signed in and what they may do. Rendered into navigation and
  /// never trusted as authority — every route re-checks server-side.
  Future<AdminIdentityDto> identity();

  Future<List<AdminOperatorDto>> operators({
    Set<String> statuses = const {},
    required String reason,
  });

  Future<AdminOperatorDetailDto> operatorDetail(
    String id, {
    required String reason,
  });

  Future<AdminOperatorDto> decide({
    required String operatorId,
    required String decision,
    required String reason,
    String? detail,
  });

  Future<AdminOperatorDto> setCommission({
    required String operatorId,
    required int commissionBps,
    required String reason,
  });

  Future<List<UnresolvedPaymentDto>> unresolvedPayments({
    required String reason,
  });

  /// The payout queue: prepared and not yet paid, oldest first.
  Future<List<PayoutRunDto>> payouts({required String reason});

  Future<PayoutRunDto> preparePayout({
    required String operatorId,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String reason,
  });

  /// `approve` or `release`. Two calls, by two different people (ADR-0011).
  Future<PayoutRunDto> decidePayout({
    required String runId,
    required String decision,
    required String reason,
    String? paymentReference,
  });

  Future<UnresolvedPaymentDto> resolvePayment({
    required String intentId,
    required String outcome,
    required String reason,
    String? evidence,
    String? failureCode,
  });
}
