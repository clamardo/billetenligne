import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

void main() {
  group('a whole-org caller', () {
    test('may grant any known role, at any station', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: true,
        callerStationIds: const [],
        requestedRoles: const {'finance'},
        requestedStationIds: const [],
      );
      expect(refusal, isNull);
    });

    test('may grant a second org_owner', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: true,
        callerStationIds: const [],
        requestedRoles: const {'org_owner'},
        requestedStationIds: const [],
      );
      expect(refusal, isNull);
    });
  });

  group('a station-scoped caller', () {
    test('may grant vendor at a station they cover', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: false,
        callerStationIds: const ['station-a'],
        requestedRoles: const {'vendor'},
        requestedStationIds: const ['station-a'],
      );
      expect(refusal, isNull);
    });

    test('may grant conductor and vendor together', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: false,
        callerStationIds: const ['station-a'],
        requestedRoles: const {'vendor', 'conductor'},
        requestedStationIds: const ['station-a'],
      );
      expect(refusal, isNull);
    });

    test('is refused a whole-org role', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: false,
        callerStationIds: const ['station-a'],
        requestedRoles: const {'finance'},
        requestedStationIds: const ['station-a'],
      );
      expect(refusal, StaffAssignmentRefusal.roleNotPermitted);
    });

    test('cannot mix a permitted role with one that is not', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: false,
        callerStationIds: const ['station-a'],
        requestedRoles: const {'vendor', 'station_manager'},
        requestedStationIds: const ['station-a'],
      );
      expect(refusal, StaffAssignmentRefusal.roleNotPermitted);
    });

    test('is refused an empty station list — that would mean every station', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: false,
        callerStationIds: const ['station-a'],
        requestedRoles: const {'vendor'},
        requestedStationIds: const [],
      );
      expect(refusal, StaffAssignmentRefusal.stationRequired);
    });

    test('is refused a station they do not themselves cover', () {
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: false,
        callerStationIds: const ['station-a'],
        requestedRoles: const {'vendor'},
        requestedStationIds: const ['station-a', 'station-b'],
      );
      expect(refusal, StaffAssignmentRefusal.stationNotCovered);
    });
  });

  test('no roles at all is refused for any caller', () {
    final refusal = StaffAssignment.validate(
      callerIsWholeOrg: true,
      callerStationIds: const [],
      requestedRoles: const {},
      requestedStationIds: const [],
    );
    expect(refusal, StaffAssignmentRefusal.noRoles);
  });

  test('an unknown role is refused before the station check runs', () {
    final refusal = StaffAssignment.validate(
      callerIsWholeOrg: false,
      callerStationIds: const ['station-a'],
      requestedRoles: const {'regional_director'},
      requestedStationIds: const [],
    );
    expect(refusal, StaffAssignmentRefusal.unknownRole);
  });
}
