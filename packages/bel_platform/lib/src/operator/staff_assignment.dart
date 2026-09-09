/// Who may grant which roles, and at which stations (ADR-0011's role
/// matrix), enforced rather than merely documented.
///
/// **Why a station-scoped caller is restricted at all.** `staff.manage` is
/// held by `station_manager` as well as `org_owner` and `org_admin` — on
/// purpose, so a shift can be covered without escalating to the owner. But
/// nothing about holding that capability should let a till agent's manager
/// promote a friend to `finance` from the same screen that invites a
/// vendor. The restriction is keyed on the caller's own station scope, not
/// on their role name — `TenantScope.stationIds.isEmpty` already means
/// "whole org" everywhere else in this codebase, and reusing that fact here
/// means no second concept of "whole-org caller" has to be invented or kept
/// in sync with the role matrix.
///
/// Lives beside `operator_application.dart` rather than in the transport
/// package: this is a fact about an operator's own governance, not about a
/// seat, a departure or a fare, and every vertical will ask the same
/// question of its own operators.
final class StaffAssignment {
  const StaffAssignment._();

  /// Every role the console understands. An unknown string is refused here
  /// rather than accepted and read back as nothing by `Capability` — a typo
  /// in a role name should be a 400, not a member of staff with no
  /// capabilities and no error anywhere saying why.
  static const knownRoles = {
    'org_owner',
    'org_admin',
    'finance',
    'fleet_manager',
    'dispatcher',
    'station_manager',
    'vendor',
    'conductor',
    // Separate from `conductor`, because on an intercity coach here they are
    // usually two people and only one of them holds the handset that marks a
    // passenger boarded. It grants **no** console capability at all: it is a
    // qualification, not an office. What it makes possible is being rostered
    // onto a departure (`CrewAssignment`), and being the person who says the
    // coach has left.
    'driver',
    'viewer',
  };

  /// The only roles a station-scoped caller may grant — the ones that work a
  /// till or a coach. Everything else is a whole-org decision.
  ///
  /// `driver` belongs here for the reason the other two do: a station manager
  /// covering tomorrow's shift at six in the morning must be able to do it
  /// without waking the owner, and the blast radius of the mistake is one
  /// station rather than the company.
  static const stationScopedRoles = {'vendor', 'conductor', 'driver'};

  /// Null on success; a reason otherwise. Pure and total: every input either
  /// passes or names exactly why it does not, so a route never has to guess
  /// which check failed.
  ///
  /// [customRoleNames] are this operator's own cloned roles (`CustomRole`,
  /// resolved by the caller against the database — this function stays
  /// DB-free). No custom role is ever a member of [stationScopedRoles]: a
  /// custom role is always a whole-org decision, the same as `finance` or
  /// `fleet_manager` and for the same reason (only a whole-org caller may
  /// design one — see `CustomRoleDefinition`), so a station-scoped caller
  /// naming one falls straight into [StaffAssignmentRefusal.roleNotPermitted]
  /// below without a separate check.
  static StaffAssignmentRefusal? validate({
    required bool callerIsWholeOrg,
    required List<String> callerStationIds,
    required Set<String> requestedRoles,
    required List<String> requestedStationIds,
    Set<String> customRoleNames = const {},
  }) {
    if (requestedRoles.isEmpty) return StaffAssignmentRefusal.noRoles;
    for (final role in requestedRoles) {
      if (!knownRoles.contains(role) && !customRoleNames.contains(role)) {
        return StaffAssignmentRefusal.unknownRole;
      }
    }

    if (callerIsWholeOrg) return null;

    if (requestedRoles.any((role) => !stationScopedRoles.contains(role))) {
      return StaffAssignmentRefusal.roleNotPermitted;
    }
    if (requestedStationIds.isEmpty) {
      return StaffAssignmentRefusal.stationRequired;
    }
    if (requestedStationIds.any((s) => !callerStationIds.contains(s))) {
      return StaffAssignmentRefusal.stationNotCovered;
    }
    return null;
  }
}

enum StaffAssignmentRefusal {
  /// A staff member with no roles at all is not a smaller grant than one
  /// role — it is a row nobody can explain, and the console must never
  /// produce one.
  noRoles,

  /// A role string this codebase has no capabilities for.
  unknownRole,

  /// A station-scoped caller tried to grant a whole-org role.
  roleNotPermitted,

  /// A station-scoped caller granted a station-scoped role with no station
  /// named — `vendor` with an empty station list means every station, which
  /// is exactly the whole-org authority this check exists to withhold.
  stationRequired,

  /// A station-scoped caller named a station they do not themselves cover.
  stationNotCovered,
}
