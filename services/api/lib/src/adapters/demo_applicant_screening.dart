import 'package:bel_domain/bel_domain.dart';

import '../application/ports/review_queue.dart';

/// Screening for a deployment that has no screening contract, so the demo
/// world can be walked end to end.
///
/// There is no sanctions vendor, which means [NoApplicantScreening] answers
/// `notRun` and automatic approval never fires — correct in production, and
/// useless for showing anybody that the path works. This answers `clear`
/// instead, so a seeded applicant is activated by the pass exactly as a real
/// one eventually will be.
///
/// **It is scoped to seeded companies, not to an environment.** The obvious
/// implementation is "return clear when `BEL__SCREENING=demo`", and the
/// obvious failure is that variable surviving into a real deployment and
/// auto-approving a real operator that nobody screened. So the marker is the
/// operator's own code — the same `DEMO-` prefix `tool/seed_demo.dart` writes
/// and `--purge` deletes — and anything else still falls to a person even
/// with this adapter wired. A flag left on can then cost nothing, because
/// there is nothing for it to clear.
final class DemoApplicantScreening implements ApplicantScreening {
  const DemoApplicantScreening({this.prefix = 'DEMO-'});

  final String prefix;

  @override
  Future<ScreeningOutcome> screen({
    required String operatorId,
    required String code,
    String? ownerName,
    String? ownerIdNumber,
  }) async => code.toUpperCase().startsWith(prefix)
      ? ScreeningOutcome.clear
      : ScreeningOutcome.notRun;
}
