import 'staff_assignment.dart';

/// Whether an operator-defined role may be created or changed (ADR-0011's
/// "capability strings, never role names, in every check... a new role is
/// then a configuration row, not a release" — this is that configuration
/// row's own gate).
///
/// **Why capabilities must be a subset of the caller's own.** A custom role
/// is authority handed to someone else, and nobody holding `staff.manage`
/// should be able to compose a role that outruns their own reach — the same
/// reasoning `StaffAssignment` already applies to *fixed* roles applies here
/// with more force, because a custom role's capability set is chosen
/// free-form rather than picked off a short list ADR-0011 already vetted.
/// Checking it against the caller's own capabilities also catches an unknown
/// or mistyped capability string for free: no string that is not a real
/// `Capability` constant can ever be part of anyone's own capability set, so
/// there is no need to duplicate `Capability`'s ~30-entry universe inside
/// this package just to reject a typo.
///
/// Lives beside `staff_assignment.dart` for the same reason that one is not
/// in the transport package: which capabilities a role carries is a fact
/// about an operator's own governance, not about a seat, a departure or a
/// fare.
final class CustomRoleDefinition {
  const CustomRoleDefinition._();

  /// Null on success; a reason otherwise. Pure and total, like
  /// `StaffAssignment.validate` — every input either passes or names exactly
  /// why it does not.
  ///
  /// [callerIsWholeOrg] mirrors `StaffAssignment.stationScopedRoles`'s own
  /// boundary: a station manager may grant `vendor` at their own station, but
  /// designing what a role *means* — which capabilities it carries at all —
  /// is a whole-org decision, the same as granting `finance` is.
  static CustomRoleRefusal? validate({
    required String name,
    required Set<String> capabilities,
    required Set<String> callerCapabilities,
    required bool callerIsWholeOrg,
  }) {
    if (!callerIsWholeOrg) return CustomRoleRefusal.callerNotWholeOrg;

    final trimmed = name.trim();
    if (trimmed.isEmpty) return CustomRoleRefusal.nameRequired;
    // A custom role sits in the same `operator_staff.roles` array as the
    // built-in ones (`StaffAssignment.knownRoles`) — letting one shadow a
    // built-in name would make an assignment's meaning depend on which row
    // happens to exist that day.
    if (StaffAssignment.knownRoles.contains(trimmed)) {
      return CustomRoleRefusal.nameCollidesWithDefault;
    }
    if (capabilities.isEmpty) return CustomRoleRefusal.noCapabilities;
    if (capabilities.any((c) => !callerCapabilities.contains(c))) {
      return CustomRoleRefusal.exceedsOwnCapabilities;
    }
    return null;
  }
}

enum CustomRoleRefusal {
  /// A station-scoped caller tried to design or change a role at all.
  callerNotWholeOrg,

  /// A role with no name is not a smaller grant than a named one — it is a
  /// row nobody could pick out of a list.
  nameRequired,

  /// A custom role named the same as one of `StaffAssignment.knownRoles`.
  nameCollidesWithDefault,

  /// A role with no capabilities at all grants nothing and explains nothing.
  noCapabilities,

  /// Would hand out a capability the caller does not themselves hold —
  /// privilege escalation, and (see class doc) the same check that would
  /// catch a typo'd capability string.
  exceedsOwnCapabilities,
}
