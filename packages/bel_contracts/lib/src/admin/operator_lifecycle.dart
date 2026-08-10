/// Which decisions an operator's current status allows.
///
/// `03-operator-lifecycle.md` §1, as a table rather than as a chain of ifs —
/// and in the **contracts** package rather than in the server, because two
/// places need it and they must not disagree:
///
///   * the server guards the transition in SQL, so two reviewers approving one
///     application at the same moment produce one approval;
///   * the back office greys the buttons a status does not allow, so a
///     reviewer is not invited to press something that will 409.
///
/// The server is the authority and the screen is the courtesy. Sharing the
/// table is what stops the courtesy from becoming a lie.
abstract final class OperatorLifecycle {
  /// The states waiting on a human.
  static const pending = <String>{
    'registered',
    'application_draft',
    'under_review',
    'kyb_verifying',
    'info_requested',
  };

  static const allowedFrom = <String, Set<String>>{
    'approve': pending,
    'activate': {'approved'},
    // Deliberately narrower than `approve`: asking for more paperwork from an
    // operator whose application was never really started, or has already been
    // answered once, is how a queue grows a tail nobody works.
    'requestInfo': {'registered', 'under_review', 'kyb_verifying'},
    'reject': pending,
    'suspend': {'approved', 'active'},
    'reinstate': {'suspended'},
  };

  /// In the order a reviewer meets them: move it forward, ask for more, refuse
  /// it — and then the two that apply to somebody already selling.
  static const decisions = <String>[
    'approve',
    'activate',
    'requestInfo',
    'reject',
    'suspend',
    'reinstate',
  ];

  static bool allows(String decision, String status) =>
      allowedFrom[decision]?.contains(status) ?? false;

  /// What a status may become. Empty means the file is closed — `rejected`
  /// and `offboarded` are terminal, and a screen that offers a button there
  /// is a screen that teaches people our buttons lie.
  static List<String> decisionsFrom(String status) => [
    for (final d in decisions) if (allows(d, status)) d,
  ];
}
