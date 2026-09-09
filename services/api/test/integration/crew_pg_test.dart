@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:postgres/postgres.dart' hide Result;
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// J3 — a departure has people on it.
///
/// The half of this that a unit test cannot reach is the schema itself.
/// `CrewAssignment.validate` is proved pure in `bel_platform`; what is proved
/// here is that the database refuses the same things **without being asked**,
/// which is what keeps the rule true for the next caller nobody has written.
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorConsole console;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  group('putting somebody on a coach', () {
    test('a qualified driver is rostered, and reads back', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final driver = await fixture.staffMember(
        roles: const ['driver'],
        suffix: '0001',
        name: 'Aline Mbemba',
        staffRef: 'CH-014',
      );
      final actor = await fixture.staffMember(
        roles: const ['dispatcher'],
        suffix: '0002',
      );

      final result = await console.assignCrew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        staffUserId: driver,
        role: CrewRole.driver,
        actorUserId: actor,
      );

      expect(result, isA<Ok<CrewMember, CrewAssignmentRefusal>>());

      final crew = await console.crew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
      );
      expect(crew, hasLength(1));
      expect(crew.single.userId, driver);
      expect(crew.single.role, CrewRole.driver);
      // The roster is read by humans looking for a person, so it carries the
      // name and the operator's own number rather than only an id.
      expect(crew.single.fullName, 'Aline Mbemba');
      expect(crew.single.staffRef, 'CH-014');
    });

    // One person, both jobs, one run. A three-coach company works this way and
    // a schema that forbade it would be a schema they cannot use.
    test('the same person may drive and conduct the same run', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final person = await fixture.staffMember(
        roles: const ['driver', 'conductor'],
        suffix: '0003',
      );

      for (final role in CrewRole.values) {
        expect(
          await console.assignCrew(
            operatorId: PgFixture.operatorId,
            departureId: departureId,
            staffUserId: person,
            role: role,
            actorUserId: person,
          ),
          isA<Ok<CrewMember, CrewAssignmentRefusal>>(),
        );
      }

      final crew = await console.crew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
      );
      expect(crew.map((c) => c.role), containsAll(CrewRole.values));
    });

    test('rostering the same person twice is a no-op, not a refusal', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final driver = await fixture.staffMember(suffix: '0004');

      for (var i = 0; i < 2; i++) {
        expect(
          await console.assignCrew(
            operatorId: PgFixture.operatorId,
            departureId: departureId,
            staffUserId: driver,
            role: CrewRole.driver,
            actorUserId: driver,
          ),
          isA<Ok<CrewMember, CrewAssignmentRefusal>>(),
          reason: 'a dispatcher tapping twice means it once',
        );
      }

      expect(
        await console.crew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
        ),
        hasLength(1),
      );
    });
  });

  group('who the port refuses, with a reason', () {
    test('somebody who does not work here', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final stranger = await fixture.traveller('7001');

      expect(
        await console.assignCrew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          staffUserId: stranger,
          role: CrewRole.driver,
          actorUserId: stranger,
        ),
        isA<Err<CrewMember, CrewAssignmentRefusal>>().having(
          (e) => e.failure,
          'failure',
          CrewAssignmentRefusal.notStaff,
        ),
      );
    });

    test('staff, but not in that job', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final clerk = await fixture.staffMember(
        roles: const ['vendor'],
        suffix: '0005',
      );

      expect(
        await console.assignCrew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          staffUserId: clerk,
          role: CrewRole.driver,
          actorUserId: clerk,
        ),
        isA<Err<CrewMember, CrewAssignmentRefusal>>().having(
          (e) => e.failure,
          'failure',
          CrewAssignmentRefusal.notQualified,
        ),
      );
    });

    test('somebody whose access was revoked', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final gone = await fixture.staffMember(
        suffix: '0006',
        revokedAt: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );

      expect(
        await console.assignCrew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          staffUserId: gone,
          role: CrewRole.driver,
          actorUserId: gone,
        ),
        isA<Err<CrewMember, CrewAssignmentRefusal>>().having(
          (e) => e.failure,
          'failure',
          CrewAssignmentRefusal.revoked,
        ),
      );
    });

    test('a coach that has already left', () async {
      // A roster is a plan. Changing the plan for a coach on the road is a
      // claim about the past.
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: -2),
      );
      final driver = await fixture.staffMember(suffix: '0007');

      expect(
        await console.assignCrew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          staffUserId: driver,
          role: CrewRole.driver,
          actorUserId: driver,
        ),
        isA<Err<CrewMember, CrewAssignmentRefusal>>().having(
          (e) => e.failure,
          'failure',
          CrewAssignmentRefusal.departed,
        ),
      );
    });
  });

  // The reason the constraint is in the schema and not only in Dart: it has to
  // hold for code nobody has written yet.
  group('what the database refuses on its own', () {
    test(
      'a roster row for somebody who is not staff of that operator',
      () async {
        final departureId = await fixture.departure(seatLabels: const ['1A']);
        final stranger = await fixture.traveller('7002');

        await expectLater(
          fixture.rosterRaw(departureId: departureId, userId: stranger),
          throwsA(
            isA<ServerException>().having(
              (e) => e.code,
              'sqlstate',
              '23503', // foreign_key_violation
            ),
          ),
          reason: 'departure_crew_is_staff, not a check in a handler',
        );
      },
    );
  });

  // §4.2: the operator's own number for somebody. An identifier and never a
  // credential — it is printed on the roster and stuck to the dashboard of
  // the coach — and unique within one company, because a dispatcher saying
  // "quatorze" on the radio has to mean one person.
  group('the staff number', () {
    test('is set on the assignment, and read back on the roster', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final driver = await fixture.staffMember(suffix: '0013');

      final updated = await console.updateStaffAssignment(
        operatorId: PgFixture.operatorId,
        staffId: await fixture.staffRowId(driver),
        roles: const ['driver'],
        stationIds: const [],
        staffRef: 'CH-018',
      );
      expect(updated.refTaken, isFalse);
      expect(updated.staff?.staffRef, 'CH-018');

      await console.assignCrew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        staffUserId: driver,
        role: CrewRole.driver,
        actorUserId: driver,
      );

      final crew = await console.crew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
      );
      expect(crew.single.staffRef, 'CH-018');
    });

    test('cannot be two people at one company', () async {
      final first = await fixture.staffMember(suffix: '0014');
      final second = await fixture.staffMember(suffix: '0015');

      await console.updateStaffAssignment(
        operatorId: PgFixture.operatorId,
        staffId: await fixture.staffRowId(first),
        roles: const ['driver'],
        stationIds: const [],
        staffRef: 'CH-021',
      );

      // The index decides, not a read-then-write a second dispatcher could
      // slip between — and the caller gets a reason rather than a 500.
      final clash = await console.updateStaffAssignment(
        operatorId: PgFixture.operatorId,
        staffId: await fixture.staffRowId(second),
        roles: const ['driver'],
        stationIds: const [],
        staffRef: 'CH-021',
      );
      expect(clash.refTaken, isTrue);
      expect(clash.staff, isNull);
    });

    test('and blank is no number, so two of those are fine', () async {
      final first = await fixture.staffMember(suffix: '0016');
      final second = await fixture.staffMember(suffix: '0017');

      for (final person in [first, second]) {
        final updated = await console.updateStaffAssignment(
          operatorId: PgFixture.operatorId,
          staffId: await fixture.staffRowId(person),
          roles: const ['driver'],
          stationIds: const [],
        );
        expect(updated.refTaken, isFalse);
        expect(updated.staff?.staffRef, isNull);
      }
    });
  });

  // The asymmetry §4.2 asks for, and the half a pure rule cannot deliver:
  // `CrewAssignment.revocationClears` states it, and this proves something
  // actually does it.
  group('what a revocation clears', () {
    test('every run still to come', () async {
      final tomorrow = await fixture.departure(seatLabels: const ['1A']);
      final driver = await fixture.staffMember(suffix: '0011');
      await console.assignCrew(
        operatorId: PgFixture.operatorId,
        departureId: tomorrow,
        staffUserId: driver,
        role: CrewRole.driver,
        actorUserId: driver,
      );

      expect(
        await console.revokeStaff(
          operatorId: PgFixture.operatorId,
          staffId: await fixture.staffRowId(driver),
        ),
        isTrue,
      );

      // Otherwise a station manager is sent into a yard at half past five
      // looking for somebody who can no longer sign in.
      expect(
        await console.crew(
          operatorId: PgFixture.operatorId,
          departureId: tomorrow,
        ),
        isEmpty,
      );
    });

    test('and nothing that has already run', () async {
      final past = await fixture.departure(seatLabels: const ['1A']);
      final driver = await fixture.staffMember(suffix: '0012');
      await console.assignCrew(
        operatorId: PgFixture.operatorId,
        departureId: past,
        staffUserId: driver,
        role: CrewRole.driver,
        actorUserId: driver,
      );
      // Rostered while it was still a plan, then the coach went. Backdated
      // rather than created in the past, because assigning onto a departed
      // coach is exactly what the port refuses.
      await fixture.departLongAgo(past, const Duration(hours: 3));

      await console.revokeStaff(
        operatorId: PgFixture.operatorId,
        staffId: await fixture.staffRowId(driver),
      );

      // The manifest for last Tuesday is a record of who was on the coach,
      // and a record that edits itself when somebody resigns is not a record.
      expect(
        await console.crew(operatorId: PgFixture.operatorId, departureId: past),
        hasLength(1),
      );
    });
  });

  group('taking somebody off', () {
    test('removes exactly that job, leaving the other', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final person = await fixture.staffMember(
        roles: const ['driver', 'conductor'],
        suffix: '0008',
      );
      for (final role in CrewRole.values) {
        await console.assignCrew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          staffUserId: person,
          role: role,
          actorUserId: person,
        );
      }

      await console.unassignCrew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        staffUserId: person,
        role: CrewRole.driver,
      );

      final crew = await console.crew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
      );
      expect(crew.single.role, CrewRole.conductor);
    });

    test('removing nobody is not an error', () async {
      final departureId = await fixture.departure(seatLabels: const ['1A']);
      final driver = await fixture.staffMember(suffix: '0009');

      final result = await console.unassignCrew(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        staffUserId: driver,
        role: CrewRole.driver,
      );

      expect(result, isA<Ok<bool, CrewAssignmentRefusal>>());
      expect((result as Ok<bool, CrewAssignmentRefusal>).value, isFalse);
    });

    test('a coach that has already left keeps its crew', () async {
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: -2),
      );
      final driver = await fixture.staffMember(suffix: '0010');

      expect(
        await console.unassignCrew(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          staffUserId: driver,
          role: CrewRole.driver,
        ),
        isA<Err<bool, CrewAssignmentRefusal>>().having(
          (e) => e.failure,
          'failure',
          CrewAssignmentRefusal.departed,
        ),
      );
    });
  });
}
