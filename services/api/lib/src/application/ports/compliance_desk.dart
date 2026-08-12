import 'package:bel_contracts/bel_contracts.dart';

/// Where every operator stands against the expiry calendar
/// (`03-operator-lifecycle.md` §3.3, §6).
///
/// Two readers, one record. The operator sees its own standing as a banner in
/// the console; we see everybody's as the **Conformité** screen. They are the
/// same facts because an enforcement that the enforced party cannot see the
/// grounds for is an argument waiting to happen — the operator must be able
/// to read the exact date we are acting on.
///
/// **Read-only, on purpose.** Nothing here sets or clears a block: the
/// compliance pass does that from the calendar, and an endpoint that could
/// clear it would be an operator clearing its own.
abstract interface class ComplianceDesk {
  /// One operator's standing, under its own tenant scope.
  Future<ComplianceDto> standing(String operatorId);

  /// Everybody with something dated inside [withinDays], worst first.
  ///
  /// Includes what has already lapsed — a calendar that only looked forward
  /// would drop an operator off the screen at the exact moment they became
  /// the reason somebody has to make a phone call.
  Future<List<ComplianceDto>> calendar({
    required String actorUserId,
    int withinDays = 60,
  });
}

/// The fakes composition's answer: nothing dated, nothing blocked.
final class NoComplianceDesk implements ComplianceDesk {
  const NoComplianceDesk();

  @override
  Future<ComplianceDto> standing(String operatorId) async =>
      ComplianceDto(operatorId: operatorId, stage: 'clear');

  @override
  Future<List<ComplianceDto>> calendar({
    required String actorUserId,
    int withinDays = 60,
  }) async => const [];
}
