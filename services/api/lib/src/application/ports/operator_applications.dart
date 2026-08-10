import 'package:bel_domain/bel_domain.dart';

/// An application, as the applicant's own wizard sees it.
///
/// The operator row and the application row, read together. They are two
/// tables for a good reason — the selling path reads `operators` on every
/// search and has no business carrying somebody's ID number — and exactly one
/// thing from the applicant's point of view.
final class OperatorApplication {
  const OperatorApplication({
    required this.operatorId,
    required this.code,
    required this.status,
    required this.facts,
    required this.createdAt,
    this.submittedAt,
    this.decisionReason,
  });

  final String operatorId;

  /// Generated, never chosen (`blt.cg/o/<code>`).
  final String code;

  /// The lifecycle state in `03-operator-lifecycle.md` §1, as the column
  /// stores it: `application_draft`, `under_review`, `info_requested`,
  /// `approved`, `active`, `rejected`.
  final String status;

  final ApplicationFacts facts;
  final DateTime createdAt;
  final DateTime? submittedAt;

  /// Why a reviewer asked for more, or refused. The applicant is entitled to
  /// the sentence somebody typed about them — a queue that rejects without
  /// one produces a phone call, which is the cost the whole surface exists to
  /// avoid.
  final String? decisionReason;

  bool get isEditable =>
      status == 'application_draft' || status == 'info_requested';
}

/// Why an application call was refused. A fact about the application, never
/// about the request.
enum ApplicationRefusal {
  /// This account already has one in flight. Re-application after a rejection
  /// is a different thing and is allowed (§2.3, after thirty days).
  alreadyApplied,

  /// Nothing to save — this account has never started one.
  noApplication,

  /// Under review, approved or rejected. The wizard reopens when a reviewer
  /// asks for information and not before.
  locked,

  /// Submit was called on something with gaps. The list of them comes from
  /// the domain, and the client already knows it — this is the server
  /// refusing to take the client's word for it.
  incomplete,
}

/// Self-signup, as the applicant drives it (`03-operator-lifecycle.md` §2.2).
///
/// Every method is keyed to a **user id and nothing else**. There is no
/// operator id in these signatures on purpose: the caller belongs to no
/// tenant — that is the entire situation — so a method that accepted one
/// would be a method that could be pointed at somebody else's application.
abstract interface class OperatorApplications {
  /// Whatever this account is applying with, or null.
  Future<OperatorApplication?> mine({required String userId});

  /// Starts one. The operator row is created here, in
  /// `application_draft`, which is the only status the public surface can
  /// write.
  Future<Result<OperatorApplication, ApplicationRefusal>> start({
    required String userId,
    required String legalName,
    required String marketCode,
  });

  /// Saves the whole record.
  ///
  /// Whole rather than per field, and idempotent because of it: "save on
  /// every field" (§2.2) over a connection that drops is a stream of partial
  /// writes, and a full replace makes the last one win rather than making the
  /// order matter.
  Future<Result<OperatorApplication, ApplicationRefusal>> save({
    required String userId,
    required ApplicationFacts facts,
  });

  /// Hands it to the review queue. Refuses anything incomplete, judged
  /// against [asOf] so an expired insurance certificate is caught here rather
  /// than by a reviewer.
  Future<Result<OperatorApplication, ApplicationRefusal>> submit({
    required String userId,
    required DateTime asOf,
  });
}
