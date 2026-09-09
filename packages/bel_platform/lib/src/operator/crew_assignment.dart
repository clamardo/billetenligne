/// The two jobs a person does on a departure.
///
/// Separate because they are separate on the coach. On an intercity run here
/// the person driving and the person taking tickets at the door are usually
/// two people, and which of them holds the operator-owned handset decides who
/// can mark a passenger boarded and whose tap is evidence in a delay dispute.
/// A single `crew` role would have collapsed that on day one.
enum CrewRole {
  driver,
  conductor;

  static CrewRole? byName(String? raw) {
    for (final role in values) {
      if (role.name == raw) return role;
    }
    return null;
  }

  /// The `operator_staff.roles` entry a person must already hold to be
  /// rostered in this job.
  ///
  /// `conductor` is one of ADR-0011's roles and has been since the first
  /// migration — it is what the scanner authorises against. `driver` is new
  /// with the crew, and is deliberately the *same* string in both places
  /// rather than a parallel vocabulary: a person is a driver, and a rota entry
  /// says which day.
  String get staffRole => name;

  String get labelKey => 'enum.CrewRole.$name';
}

enum CrewAssignmentRefusal {
  /// Not `driver` or `conductor`. A dispatcher cannot roster somebody as
  /// `finance`.
  unknownRole,

  /// This person is not staff of this operator, or no longer is. The database
  /// refuses it too (`departure_crew_is_staff`), which is what makes the rule
  /// true for callers nobody has written yet — this is the copy that produces
  /// a sentence instead of a constraint violation.
  notStaff,

  /// Staff, but not in this job. Somebody who sells tickets at a counter is
  /// not thereby licensed to drive a coach, and the roster is the wrong place
  /// to discover that.
  notQualified,

  /// Their access was revoked. Allowed on a departure that has already run —
  /// the past is a record, and who drove the coach on Tuesday does not become
  /// untrue when they leave on Friday — and refused on one still to come.
  revoked,

  /// The departure has already gone. A roster is a plan; changing the plan
  /// for a coach that is on the road is a claim about the past.
  departed,
}

/// Who may be put on which coach, as a pure rule.
///
/// Kept out of the adapter for the same reason [StaffAssignment] is: the
/// database enforces *membership* — `departure_crew_is_staff` makes rostering
/// a stranger or another operator's employee impossible rather than merely
/// refused — but a constraint cannot tell a dispatcher **why**, and the two
/// interesting cases here are about time rather than about set membership.
final class CrewAssignment {
  const CrewAssignment._();

  /// Null on success; a reason otherwise. Pure and total, so a route never has
  /// to guess which check failed.
  ///
  /// [staffRoles] is what `operator_staff.roles` holds for this person, and
  /// [revokedAt] is their `revoked_at`. Both are read by the caller — this
  /// function stays database-free.
  static CrewAssignmentRefusal? validate({
    required CrewRole? role,
    required bool isStaff,
    required Set<String> staffRoles,
    required DateTime? revokedAt,
    required DateTime departsAt,
    required DateTime now,
  }) {
    if (role == null) return CrewAssignmentRefusal.unknownRole;
    if (!isStaff) return CrewAssignmentRefusal.notStaff;

    // Checked before revocation and before departure, because "you cannot
    // drive" is a more useful sentence than "that departure has gone" to
    // somebody who was never going to be allowed either way.
    if (!staffRoles.contains(role.staffRole)) {
      return CrewAssignmentRefusal.notQualified;
    }

    // A departure already on the road cannot have its plan changed. Checked
    // before revocation so that a *past* run is refused for the honest reason
    // rather than for a revocation that happened afterwards.
    if (!departsAt.isAfter(now)) return CrewAssignmentRefusal.departed;

    if (revokedAt != null) return CrewAssignmentRefusal.revoked;

    return null;
  }

  /// Whether a revocation should clear this person off a departure.
  ///
  /// The asymmetry is the point. Revoking somebody's access removes them from
  /// every run still to come — that is what revocation *means*, and a roster
  /// that still named them would send a station manager looking for a person
  /// who can no longer sign in. It touches nothing that has already run,
  /// because the manifest for last Tuesday is a record of who was on the
  /// coach, and a record that edits itself when somebody resigns is not a
  /// record.
  static bool revocationClears({
    required DateTime departsAt,
    required DateTime revokedAt,
  }) => departsAt.isAfter(revokedAt);
}
