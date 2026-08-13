import 'package:bel_domain/bel_domain.dart';

/// One submitted application, and the two facts about it the domain cannot
/// work out for itself.
final class PendingApplication {
  const PendingApplication({
    required this.operatorId,
    required this.code,
    required this.legalName,
    required this.facts,
    this.duplicate = false,
    this.priorOffboarding = false,
  });

  final String operatorId;

  /// The operator's short code. Carried here for one reason: a demo
  /// deployment has to be able to tell a seeded company from a real one
  /// **without a flag anybody can leave switched on** — see
  /// `DemoApplicantScreening`.
  final String code;

  final String legalName;
  final ApplicationFacts facts;

  /// Another operator already carries this RCCM number or this legal name.
  /// Not necessarily fraud — a company re-applying after a rejection lands
  /// here too — and always a person's decision.
  final bool duplicate;

  /// The same applicant has been offboarded or rejected before. §5.3 keeps
  /// that history precisely so a reviewer can see it.
  final bool priorOffboarding;
}

/// The queue an automatic reviewer works (`03-operator-lifecycle.md` §2.3).
///
/// Read and written under the worker's scope, with **no actor** — nobody
/// decided, which is the point, and inventing a staff id to satisfy an audit
/// column would make the trail lie about who approved a company.
abstract interface class ReviewQueue {
  /// Submitted, undecided, and never assessed. Oldest first.
  Future<List<PendingApplication>> awaitingAssessment({int limit});

  /// Records the band and its reasons so the human queue can be worked worst
  /// first. Nothing else changes: an assessment is not a decision.
  Future<void> record({
    required String operatorId,
    required RiskBand band,
    required List<String> reasons,
  });

  /// Activates the operator with no human in the loop.
  ///
  /// Everything an approval does by hand, in one transaction: the status, the
  /// applicant becoming the first `org_owner`, the audit row attributed to
  /// the system, and the message that tells them they can sell. False when
  /// the row moved underneath us — a reviewer who reached it first wins, and
  /// that is the safe direction for the race to go.
  Future<bool> approve({required String operatorId});
}

/// The fakes composition: an empty queue, approving nobody.
final class NoReviewQueue implements ReviewQueue {
  const NoReviewQueue();

  @override
  Future<List<PendingApplication>> awaitingAssessment({int limit = 50}) async =>
      const [];

  @override
  Future<void> record({
    required String operatorId,
    required RiskBand band,
    required List<String> reasons,
  }) async {}

  @override
  Future<bool> approve({required String operatorId}) async => false;
}

/// Sanctions and PEP screening on the owner (§2.3).
///
/// A port with no production adapter, and that is the honest state of it:
/// there is no screening contract, so [NoApplicantScreening] answers
/// `notRun` and every application falls to a person. **The automatic path is
/// switched off by data rather than by dead code** — exactly like a payment
/// rail shipped without credentials — so the day a vendor exists this is one
/// adapter and no other change.
abstract interface class ApplicantScreening {
  Future<ScreeningOutcome> screen({
    required String operatorId,
    required String code,
    String? ownerName,
    String? ownerIdNumber,
  });
}

final class NoApplicantScreening implements ApplicantScreening {
  const NoApplicantScreening();

  @override
  Future<ScreeningOutcome> screen({
    required String operatorId,
    required String code,
    String? ownerName,
    String? ownerIdNumber,
  }) async => ScreeningOutcome.notRun;
}
