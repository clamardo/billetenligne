import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/operator_applications.dart';

/// Self-signup with no database.
///
/// The fakes composition exists so a fresh clone answers something useful,
/// and onboarding is the one path a fresh clone is most likely to be pointed
/// at first. It holds the same rules as the Postgres adapter — one
/// application in flight, edits only while it is the applicant's to edit, no
/// submitting something incomplete — because a fake that is more permissive
/// than the real thing teaches the client habits the server will refuse.
final class MemoryOperatorApplications implements OperatorApplications {
  MemoryOperatorApplications({required Clock clock}) : _clock = clock;

  final Clock _clock;
  final _byUser = <String, OperatorApplication>{};
  var _serial = 0;

  @override
  Future<OperatorApplication?> mine({required String userId}) async =>
      _byUser[userId];

  @override
  Future<Result<OperatorApplication, ApplicationRefusal>> start({
    required String userId,
    required String legalName,
    required String marketCode,
  }) async {
    final existing = _byUser[userId];
    if (existing != null && existing.status != 'rejected') {
      return const Err(ApplicationRefusal.alreadyApplied);
    }

    _serial++;
    final application = OperatorApplication(
      operatorId: 'op-application-$_serial',
      code: operatorCodeFrom(legalName, 'M$_serial'),
      status: 'application_draft',
      createdAt: _clock.now(),
      facts: ApplicationFacts(legalName: legalName.trim()),
    );
    _byUser[userId] = application;
    return Ok(application);
  }

  @override
  Future<Result<OperatorApplication, ApplicationRefusal>> save({
    required String userId,
    required ApplicationFacts facts,
  }) async {
    final current = _byUser[userId];
    if (current == null) return const Err(ApplicationRefusal.noApplication);
    if (!current.isEditable) return const Err(ApplicationRefusal.locked);

    final saved = OperatorApplication(
      operatorId: current.operatorId,
      code: current.code,
      status: current.status,
      createdAt: current.createdAt,
      submittedAt: current.submittedAt,
      decisionReason: current.decisionReason,
      facts: facts,
    );
    _byUser[userId] = saved;
    return Ok(saved);
  }

  @override
  Future<Result<OperatorApplication, ApplicationRefusal>> submit({
    required String userId,
    required DateTime asOf,
  }) async {
    final current = _byUser[userId];
    if (current == null) return const Err(ApplicationRefusal.noApplication);
    if (!current.isEditable) return const Err(ApplicationRefusal.locked);
    if (!current.facts.isSubmittable(asOf: asOf)) {
      return const Err(ApplicationRefusal.incomplete);
    }

    final submitted = OperatorApplication(
      operatorId: current.operatorId,
      code: current.code,
      status: 'under_review',
      createdAt: current.createdAt,
      submittedAt: _clock.now(),
      facts: current.facts,
    );
    _byUser[userId] = submitted;
    return Ok(submitted);
  }
}
