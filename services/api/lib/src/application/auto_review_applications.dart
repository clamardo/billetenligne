import 'package:bel_domain/bel_domain.dart';

import 'ports/review_queue.dart';

/// What one pass did.
final class AutoReviewResult {
  const AutoReviewResult({required this.assessed, required this.approved});

  final int assessed;

  /// Approved with nobody in the loop. Zero is the ordinary answer while no
  /// screening vendor is wired, and it is a correct answer rather than a
  /// broken one.
  final int approved;
}

/// Decides which applications a person has to read
/// (`03-operator-lifecycle.md` §2.3, `09-roadmap.md` Phase 4).
///
/// **The queue is worked oldest-first with a published 48-hour SLA, and that
/// is a promise about the tail.** The tail is mostly three-coach companies
/// whose application is complete and about which a reviewer has nothing to
/// add; every one of those a person reads is a person not reading the
/// fourteen-coach one whose name already exists in the table. So the small
/// complete ones approve themselves and the rest arrive pre-sorted.
///
/// Two things make automatic approval defensible rather than reckless, and
/// neither is in this file:
///
///   * **Exposure, not trust.** The bar is small — five coaches, six
///     departures — so the worst case is a bus-load rather than a season.
///   * **The expiry ladder is the safety net.** An operator approved here
///     whose insurance lapses is blocked from selling the day it does
///     (§3.3), by a pass with no human in it either.
///
/// Assessment and approval are separate on purpose. An application that is
/// not approved is still *sorted*, and a reviewer opening the queue on Monday
/// sees the elevated ones at the top with the reasons already written down.
final class AutoReviewApplications {
  const AutoReviewApplications({
    required ReviewQueue queue,
    required ApplicantScreening screening,
    required Clock clock,
    this.limits = const RiskLimits(),
  }) : _queue = queue,
       _screening = screening,
       _clock = clock;

  final ReviewQueue _queue;
  final ApplicantScreening _screening;
  final Clock _clock;

  /// Where the automatic bar sits. Injected rather than hard-coded, because
  /// the honest answer to "how many coaches is small" is that we will find
  /// out, and moving it should not be a release.
  final RiskLimits limits;

  Future<AutoReviewResult> run({int limit = 50}) async {
    final pending = await _queue.awaitingAssessment(limit: limit);
    var approved = 0;

    for (final application in pending) {
      // One screen per application, and only for applications that reached
      // this pass: screening is a paid third-party call, and calling it for
      // every row in the table on every run is a bill nobody budgeted.
      final screening = await _screening.screen(
        operatorId: application.operatorId,
        ownerName: application.facts.ownerName,
        ownerIdNumber: application.facts.ownerIdNumber,
      );

      final risk = OnboardingRisk.of(
        application.facts,
        screening: screening,
        duplicate: application.duplicate,
        priorOffboarding: application.priorOffboarding,
        now: _clock.now(),
        limits: limits,
      );

      // Recorded first, always, and for the approvals too — an approval whose
      // grounds were never written down is an approval nobody can explain
      // afterwards, which is the one outcome worse than a slow queue.
      await _queue.record(
        operatorId: application.operatorId,
        band: risk.band,
        reasons: risk.reasons,
      );

      if (!risk.autoApprovable) continue;
      if (await _queue.approve(operatorId: application.operatorId)) approved++;
    }

    return AutoReviewResult(assessed: pending.length, approved: approved);
  }
}
