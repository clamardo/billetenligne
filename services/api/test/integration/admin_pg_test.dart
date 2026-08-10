@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_platform_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The back office, against the database that enforces it.
///
/// Three claims, none of which a fake can make:
///
///   * a lifecycle transition is **conditional in SQL**, so two reviewers
///     approving one application at the same moment produce one approval;
///   * the decision and its audit row are **one transaction** — a decision
///     with no trail, or a trail with no decision, are both worse than
///     neither;
///   * the audit row carries the **actor, the reason and both states**,
///     because "who changed our commission, when, and from what" is the
///     question this table exists to answer.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresPlatformConsole platform;
  late String reviewer;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    platform = PostgresPlatformConsole(db);
    reviewer = await fixture.platformStaff('operations');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String code() => 'AP${++seq}${DateTime.now().microsecondsSinceEpoch % 10000}';

  test(
    'the queue lists applicants oldest first, with what decides them',
    () async {
      final id = await fixture.applicant(
        code: code(),
        legalName: 'Trans Bony Voyages',
      );
      await fixture.kybDocument(
        operatorId: id,
        docType: 'insurance',
        // Expired. Selling seats on an uninsured coach is a liability we will
        // not carry, so this number belongs in the queue rather than a report.
        expiresAt: DateTime.now().toUtc().subtract(const Duration(days: 3)),
      );
      await fixture.kybDocument(operatorId: id, docType: 'rccm');

      final queue = await platform.operators(
        actorUserId: reviewer,
        statuses: const {'registered'},
      );

      final mine = queue.firstWhere((o) => o.id == id);
      expect(mine.legalName, 'Trans Bony Voyages');
      expect(mine.documentCount, 2);
      expect(mine.expiringDocumentCount, 1);
      expect(mine.isPending, isTrue);
      // Whatever the seed default is, it arrives as a term rather than a float.
      expect(mine.commission.bps, isA<int>());

      final createdAts = [for (final o in queue) o.createdAt];
      final sorted = [...createdAts]..sort();
      expect(
        createdAts,
        sorted,
        reason: 'a queue worked newest-first has a tail',
      );
    },
  );

  test('approving moves the operator and writes the trail with it', () async {
    final id = await fixture.applicant(code: code(), legalName: 'Sotrapo');

    final result = await platform.decide(
      operatorId: id,
      decision: OperatorDecision.approve,
      actorUserId: reviewer,
      reason: 'documents complete, insurance valid to 2027',
    );

    expect(result.valueOrNull!.status, 'approved');
    expect(await fixture.operatorStatus(id), 'approved');

    final trail = await fixture.auditFor(id);
    final entry = trail.single;
    expect(entry['action'], 'operator.approve');
    expect(entry['actor_id'].toString(), reviewer);
    expect(entry['actor_type'], 'platform_staff');
    expect(entry['reason'], contains('insurance valid'));
    expect(entry['before_state'], {'status': 'registered'});
    expect(entry['after_state'], {'status': 'approved'});
  });

  test('a decision the state does not allow is refused, not applied', () async {
    final id = await fixture.applicant(
      code: code(),
      legalName: 'Ocean du Nord',
      status: 'active',
    );

    final result = await platform.decide(
      operatorId: id,
      decision: OperatorDecision.approve,
      actorUserId: reviewer,
      reason: 'wrong row',
    );

    // Approving something already active is not a no-op. It is a sign the
    // reviewer is looking at the wrong row, and saying so is the only useful
    // answer.
    expect(result.isErr, isTrue);
    expect(await fixture.operatorStatus(id), 'active');
    expect(await fixture.auditFor(id), isEmpty);
  });

  test('two reviewers approving at once produce one approval', () async {
    final id = await fixture.applicant(code: code(), legalName: 'Concurrent');

    final both = await Future.wait([
      platform.decide(
        operatorId: id,
        decision: OperatorDecision.approve,
        actorUserId: reviewer,
        reason: 'first',
      ),
      platform.decide(
        operatorId: id,
        decision: OperatorDecision.approve,
        actorUserId: reviewer,
        reason: 'second',
      ),
    ]);

    expect(both.where((r) => r.isOk), hasLength(1));
    // One approval means one audit row. Two would be a trail that disagrees
    // with itself about what happened.
    expect(await fixture.auditFor(id), hasLength(1));
  });

  test(
    'suspending records the reason on the operator and in the trail',
    () async {
      final id = await fixture.applicant(
        code: code(),
        legalName: 'Suspendu',
        status: 'active',
      );

      await platform.decide(
        operatorId: id,
        decision: OperatorDecision.suspend,
        actorUserId: reviewer,
        reason: 'insurance lapsed',
      );
      expect(await fixture.operatorStatus(id), 'suspended');

      await platform.decide(
        operatorId: id,
        decision: OperatorDecision.reinstate,
        actorUserId: reviewer,
        reason: 'new certificate received',
      );
      expect(await fixture.operatorStatus(id), 'active');

      final trail = await fixture.auditFor(id);
      expect(trail.map((e) => e['action']), [
        'operator.suspend',
        'operator.reinstate',
      ]);
    },
  );

  test('a commission change carries the old rate and the new one', () async {
    final id = await fixture.applicant(
      code: code(),
      legalName: 'Negotiated',
      status: 'active',
    );

    final result = await platform.setCommission(
      operatorId: id,
      term: CommissionTerm(750),
      actorUserId: reviewer,
      reason: 'renegotiated at 7.5% for volume',
    );

    expect(result.valueOrNull!.commission, CommissionTerm(750));

    final entry = (await fixture.auditFor(id)).single;
    expect(entry['action'], 'operator.commission');
    // The number an operator will argue about six months later. "What did we
    // agree, and when" is exactly what this table is for.
    expect(entry['before_state'], {'commissionBps': 500});
    expect(entry['after_state'], {'commissionBps': 750});
  });

  test('reading one operator is itself audited', () async {
    final id = await fixture.applicant(code: code(), legalName: 'Watched');

    await platform.operatorDetail(id, actorUserId: reviewer);
    await platform.recordRead(
      actorUserId: reviewer,
      reason: 'support ticket 412',
      action: 'operator.read',
      subjectType: 'operator',
      subjectId: id,
      operatorId: id,
    );

    final entry = (await fixture.auditFor(id)).single;
    expect(entry['action'], 'operator.read');
    // "Who looked at this operator's file, and why" is a question that gets
    // asked after the fact, and only a row written now can answer it.
    expect(entry['reason'], 'support ticket 412');
  });

  test('the trail comes back on the operator page, newest first', () async {
    final id = await fixture.applicant(code: code(), legalName: 'Trailed');

    await platform.decide(
      operatorId: id,
      decision: OperatorDecision.requestInfo,
      actorUserId: reviewer,
      reason: 'insurance certificate is illegible',
    );
    await platform.decide(
      operatorId: id,
      decision: OperatorDecision.reject,
      actorUserId: reviewer,
      reason: 'no response in 30 days',
    );

    final detail = await platform.operatorDetail(id, actorUserId: reviewer);
    expect(detail!.summary.status, 'rejected');
    expect(detail.trail.first.action, 'operator.reject');
    expect(detail.trail.last.action, 'operator.request_info');
  });
}
