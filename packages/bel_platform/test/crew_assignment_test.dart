import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 9, 6);
  final tomorrow = DateTime.utc(2026, 9, 10, 6);
  final yesterday = DateTime.utc(2026, 9, 8, 6);

  CrewAssignmentRefusal? check({
    CrewRole? role = CrewRole.driver,
    bool isStaff = true,
    Set<String> staffRoles = const {'driver', 'conductor'},
    DateTime? revokedAt,
    DateTime? departsAt,
  }) => CrewAssignment.validate(
    role: role,
    isStaff: isStaff,
    staffRoles: staffRoles,
    revokedAt: revokedAt,
    departsAt: departsAt ?? tomorrow,
    now: now,
  );

  group('who may be rostered', () {
    test('a qualified member of staff, on a run still to come', () {
      expect(check(), isNull);
    });

    test('a role that is not one of the two jobs', () {
      // A dispatcher cannot roster somebody as `finance`.
      expect(check(role: null), CrewAssignmentRefusal.unknownRole);
    });

    test('somebody who is not staff here', () {
      // The database refuses this too — `departure_crew_is_staff` makes it
      // unwritable rather than merely refused. This is the copy that produces
      // a sentence instead of a constraint violation.
      expect(check(isStaff: false), CrewAssignmentRefusal.notStaff);
    });

    test('staff, but not in this job', () {
      // Selling tickets at a counter does not license somebody to drive a
      // coach, and the roster is the wrong place to find that out.
      expect(
        check(staffRoles: const {'vendor'}),
        CrewAssignmentRefusal.notQualified,
      );
    });

    test('the two jobs are checked separately', () {
      expect(
        check(role: CrewRole.conductor, staffRoles: const {'driver'}),
        CrewAssignmentRefusal.notQualified,
      );
      expect(
        check(role: CrewRole.conductor, staffRoles: const {'conductor'}),
        isNull,
      );
    });

    // One person, both jobs. A three-coach company runs with the driver taking
    // the tickets, and a rule that forbade it would be a rule the smallest
    // operators cannot use.
    test('the same person may hold both', () {
      expect(check(role: CrewRole.driver), isNull);
      expect(check(role: CrewRole.conductor), isNull);
    });
  });

  group('time', () {
    test('a departure already gone cannot have its plan changed', () {
      expect(check(departsAt: yesterday), CrewAssignmentRefusal.departed);
    });

    test('a departure leaving exactly now is already gone', () {
      expect(check(departsAt: now), CrewAssignmentRefusal.departed);
    });

    test('revoked access cannot be rostered onto a future run', () {
      expect(check(revokedAt: yesterday), CrewAssignmentRefusal.revoked);
    });

    // Ordering, and it is deliberate: somebody who was never qualified should
    // read "you cannot drive", not "that departure has gone".
    test(
      'not being qualified is reported ahead of the departure having gone',
      () {
        expect(
          check(staffRoles: const {'vendor'}, departsAt: yesterday),
          CrewAssignmentRefusal.notQualified,
        );
      },
    );

    test(
      'a past run is refused for having gone, not for a later revocation',
      () {
        // They drove it. They resigned afterwards. "Departed" is the honest
        // reason the roster cannot be edited; "revoked" would suggest the
        // history itself was in doubt.
        expect(
          check(departsAt: yesterday, revokedAt: now),
          CrewAssignmentRefusal.departed,
        );
      },
    );
  });

  group('what a revocation clears', () {
    test('every run still to come', () {
      expect(
        CrewAssignment.revocationClears(departsAt: tomorrow, revokedAt: now),
        isTrue,
      );
    });

    // The manifest for last Tuesday is a record of who was on the coach, and a
    // record that edits itself when somebody resigns is not a record.
    test('and nothing that has already run', () {
      expect(
        CrewAssignment.revocationClears(departsAt: yesterday, revokedAt: now),
        isFalse,
      );
    });
  });

  group('the role names line up with the staff roles', () {
    // `conductor` has been one of ADR-0011's roles since the first migration —
    // it is what the scanner authorises against — so the crew role must not
    // invent a parallel spelling of it.
    test('conductor is the role the scanner already knows', () {
      expect(CrewRole.conductor.staffRole, 'conductor');
      expect(StaffAssignment.knownRoles, contains('conductor'));
    });

    test('driver is a staff role too, or nobody can ever be rostered', () {
      expect(
        StaffAssignment.knownRoles,
        contains(CrewRole.driver.staffRole),
        reason: 'a job nobody can be granted is a job nobody can do',
      );
    });

    test('an unknown name reads as nothing rather than as a default', () {
      expect(CrewRole.byName('pilot'), isNull);
      expect(CrewRole.byName(null), isNull);
      expect(CrewRole.byName('driver'), CrewRole.driver);
    });
  });
}
