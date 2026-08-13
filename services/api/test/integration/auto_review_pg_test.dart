@Tags(['integration'])
library;

import 'package:bel_api/src/application/auto_review_applications.dart';
import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/application/ports/review_queue.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_applications.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_platform_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_review_queue.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// A screen that says whatever a test needs it to.
final class _Screen implements ApplicantScreening {
  _Screen(this.outcome);
  ScreeningOutcome outcome;

  @override
  Future<ScreeningOutcome> screen({
    required String operatorId,
    required String code,
    String? ownerName,
    String? ownerIdNumber,
  }) async => outcome;
}

/// Approving an operator without a person, against the schema that has to
/// allow it (`03-operator-lifecycle.md` §2.3, `09-roadmap.md` Phase 4).
///
/// Four claims, none of which a fake can make:
///
///   * an automatic approval lands in **exactly the state** a reviewer's
///     approval lands in — active, with the applicant as `org_owner`;
///   * the audit row carries **no actor**, because nobody decided;
///   * a decision a person already took is **never overwritten**;
///   * the duplicate and prior-offboarding flags are read off the table
///     rather than believed from the application.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorApplications applications;
  late PostgresPlatformConsole platform;
  late PostgresReviewQueue queue;
  late _Screen screen;
  late String reviewer;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 6);
    applications = PostgresOperatorApplications(db);
    platform = PostgresPlatformConsole(db);
    queue = PostgresReviewQueue(db);
    screen = _Screen(ScreeningOutcome.clear);
    reviewer = await fixture.platformStaff('operations', suffix: '-auto');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  AutoReviewApplications pass() => AutoReviewApplications(
    queue: queue,
    screening: screen,
    clock: const SystemClock(),
  );

  var seq = 0;
  String suffix() =>
      '${++seq}${DateTime.now().microsecondsSinceEpoch % 100000}';

  ApplicationFacts filled({
    int fleet = 3,
    String? legalName,
    String? rccm,
    String? accountName,
  }) {
    // The settlement account name must match the legal name (§2.2 step 5), so
    // a fixture that let them drift would be testing the name check by
    // accident in every other test.
    final name = legalName ?? 'Sotrapo ${suffix()}';
    return ApplicationFacts(
      legalName: name,
      tradingName: 'Sotrapo',
      rccmNumber: rccm ?? 'CG-DLS-01-2019-B12-${suffix()}',
      taxId: 'M2019110000${suffix()}',
      legalForm: 'sarl',
      registeredAddress: '4 rue de la Gare, Dolisie',
      yearFounded: 2019,
      ownerName: 'Serge Loubaki',
      ownerIdType: 'passport',
      ownerIdNumber: '19CD98765',
      ownerPhone: '+242060192286',
      ownerEmail: 'serge@sotrapo.cg',
      transportLicenceNumber: 'TR-2025-0114',
      transportLicenceExpires: DateTime.utc(2032, 3, 31),
      insurerName: 'NSIA Congo',
      fleetInsuranceExpires: DateTime.utc(2032, 1, 31),
      routesServed: 'Dolisie - Pointe-Noire',
      fleetSize: fleet,
      stationCount: 1,
      dailyDepartures: 4,
      settlementKind: 'momo',
      settlementAccountName: accountName ?? name,
      settlementAccountRef: '+242060192286',
      agreementAccepted: true,
    );
  }

  /// A submitted application, sitting in the queue exactly as the wizard
  /// leaves it.
  Future<({String operatorId, String userId})> submitted(
    ApplicationFacts facts,
  ) async {
    final user = await fixture.traveller('8${suffix()}');
    final started = await applications.start(
      userId: user,
      legalName: facts.legalName!,
      marketCode: 'CG',
    );
    await applications.save(userId: user, facts: facts);
    await applications.submit(userId: user, asOf: DateTime.now().toUtc());
    return (operatorId: started.valueOrNull!.operatorId, userId: user);
  }

  Future<Map<String, dynamic>> columnsOf(String operatorId) async =>
      (await fixture.operatorColumns(operatorId));

  group('the pass sorts everything it sees', () {
    test('a small complete application is live, and owned', () async {
      final app = await submitted(filled());

      final result = await pass().run();

      expect(result.assessed, greaterThanOrEqualTo(1));

      final row = await columnsOf(app.operatorId);
      expect(row['status'], 'active');
      expect(row['risk_band'], 'low');
      expect(row['risk_assessed_at'], isNotNull);

      // The line that removes the phone call: approved and unable to sign in
      // is not approved.
      expect(
        await fixture.staffRoles(app.operatorId, app.userId),
        contains('org_owner'),
      );
    });

    test('nobody decided, and the trail says so', () async {
      final app = await submitted(filled());
      await pass().run();

      final trail = await fixture.auditFor(app.operatorId);
      final approval = trail.firstWhere(
        (e) => e['action'] == 'operator.approved',
      );

      expect(approval['actor_type'], 'system');
      // Inventing a staff id to satisfy a column would make the trail lie
      // about who approved a company.
      expect(approval['actor_id'], isNull);
      expect(approval['reason'], 'onboarding.auto_approved');
    });

    test('the operator is told, once', () async {
      final app = await submitted(filled());
      await pass().run();
      await pass().run();

      expect(await fixture.outboxCount('operator.approved', app.operatorId), 1);
    });

    test('a larger company is sorted and left for a person', () async {
      final app = await submitted(filled(fleet: 40));

      await pass().run();

      final row = await columnsOf(app.operatorId);
      expect(row['status'], 'under_review');
      expect(row['risk_band'], 'standard');
      expect(row['risk_reasons'], contains('fleet_too_large'));
    });

    test('with no screening, everything falls to a person', () async {
      screen.outcome = ScreeningOutcome.notRun;
      addTearDown(() => screen.outcome = ScreeningOutcome.clear);

      final app = await submitted(filled());
      await pass().run();

      final row = await columnsOf(app.operatorId);
      expect(row['status'], 'under_review');
      expect(row['risk_reasons'], contains('screening_not_run'));
    });

    test('an assessed application is not looked at twice', () async {
      final app = await submitted(filled(fleet: 40));
      await pass().run();

      // The second pass must find nothing: `risk_assessed_at` is the whole
      // filter, and a pass that re-read every decided row would spend a
      // screening call on each of them every ten minutes.
      final second = await pass().run();
      expect(second.assessed, 0);

      expect((await columnsOf(app.operatorId))['risk_band'], 'standard');
    });
  });

  group('what a person must see', () {
    test('a company whose name is already here is elevated', () async {
      final first = await submitted(filled(legalName: 'Doublon Express'));
      await pass().run();
      expect((await columnsOf(first.operatorId))['status'], 'active');

      final second = await submitted(filled(legalName: 'Doublon Express'));
      await pass().run();

      final row = await columnsOf(second.operatorId);
      expect(row['risk_band'], 'elevated');
      expect(row['risk_reasons'], contains('duplicate_operator'));
      expect(row['status'], 'under_review');
    });

    test('a decision a person already took is never overwritten', () async {
      final app = await submitted(filled());

      // The reviewer gets there first. The pass must find nothing to move.
      await platform.decide(
        operatorId: app.operatorId,
        decision: OperatorDecision.reject,
        actorUserId: reviewer,
        reason: 'documents illisibles',
      );

      await pass().run();

      expect((await columnsOf(app.operatorId))['status'], 'rejected');
    });

    test('an applicant we rejected before is elevated next time', () async {
      final app = await submitted(filled());
      await platform.decide(
        operatorId: app.operatorId,
        decision: OperatorDecision.reject,
        actorUserId: reviewer,
        reason: 'documents illisibles',
      );

      // The same person applies again with a different company. §5.3 keeps
      // that history precisely so a reviewer can see it.
      final again = await fixture.reapply(app.userId);
      await pass().run();

      final row = await columnsOf(again);
      expect(row['risk_reasons'], contains('prior_offboarding'));
      expect(row['risk_band'], 'elevated');
    });
  });
}
