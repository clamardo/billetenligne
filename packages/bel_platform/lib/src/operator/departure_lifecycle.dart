/// The six states a departure passes through, and the only ones it has.
///
/// The enum has existed in the schema since the first migration and, until
/// J4, three of its values were unreachable: `delayed` and `cancelled` were
/// written by the disruption path and `boarding`, `departed` and `arrived`
/// were written by nothing at all. A state nothing writes is a state every
/// reader has to guess at — which is why the follower page drew an estimate,
/// why nothing could close a departure, and why "tell the passenger who has
/// not arrived" had no moment at which somebody was missing.
enum DepartureState {
  scheduled,
  delayed,
  boarding,
  departed,
  arrived,
  cancelled;

  static DepartureState? byName(String? raw) {
    for (final state in values) {
      if (state.name == raw) return state;
    }
    return null;
  }

  String get labelKey => 'enum.DepartureState.$name';

  /// The coach is on the road or off it. Nobody is boarding this one.
  bool get hasLeft => this == departed || this == arrived;

  /// Nothing follows. A cancelled coach is not rescued into running again —
  /// the rescue path puts the passengers on a *different* departure — and a
  /// coach that arrived has finished.
  bool get isFinal => this == arrived || this == cancelled;
}

enum DepartureTransitionRefusal {
  /// Not one of the six. A client sending `left` or `en_route` is refused
  /// rather than quietly matched to something near it.
  unknownState,

  /// The person asking is neither rostered on this coach nor a dispatcher.
  ///
  /// Checked before anything else, because "this is not your coach" is the
  /// useful sentence for a driver holding the wrong handset — and because a
  /// capability alone would let any driver in the company close any coach in
  /// it, and closing a departure stops its sales.
  notCrew,

  /// The coach was cancelled. It is not going, and saying it has departed
  /// would put a coach on the road that the passengers were told to leave.
  cancelled,

  /// It has already gone, or already arrived. A departure that has left is a
  /// record from that moment; the ask is about the past.
  alreadyClosed,

  /// A move the road does not make — arriving without having departed, or
  /// going back to scheduled after boarding began.
  outOfOrder,

  /// Cancelling is not a state change, it is a disruption.
  ///
  /// It has to tell forty-two people, mark their bookings involuntary and
  /// open the re-accommodation paths (ADR-0016). A crew member tapping a
  /// state on a handset must not be able to do a quarter of that and leave
  /// the rest undone.
  cancelIsADisruption,
}

/// Which state may follow which, as a pure rule.
///
/// Kept out of the adapter for the same reason [CrewAssignment] is: the table
/// is the interesting part and it is worth reading in one place, without a
/// `WHERE` clause around it. What the adapter adds is the guard that makes
/// the write safe under two simultaneous taps — `WHERE status = @from` — and
/// that is a different claim from this one.
final class DepartureLifecycle {
  const DepartureLifecycle._();

  /// The whole table. Every pair not listed here is [outOfOrder].
  ///
  /// `scheduled → departed` without passing through `boarding` is legal and
  /// deliberately so: `boarding` is written by the first scan, and a coach on
  /// a road where nobody scans — a rural service where the conductor takes
  /// paper — leaves without ever having been in it.
  static const _next = <DepartureState, Set<DepartureState>>{
    DepartureState.scheduled: {
      DepartureState.delayed,
      DepartureState.boarding,
      DepartureState.departed,
      DepartureState.cancelled,
    },
    DepartureState.delayed: {
      DepartureState.boarding,
      DepartureState.departed,
      DepartureState.cancelled,
    },
    // A coach that has begun boarding can still be delayed — the passengers
    // are on it and the road ahead is closed — and can still be cancelled.
    DepartureState.boarding: {
      DepartureState.delayed,
      DepartureState.departed,
      DepartureState.cancelled,
    },
    DepartureState.departed: {DepartureState.arrived},
    DepartureState.arrived: <DepartureState>{},
    DepartureState.cancelled: <DepartureState>{},
  };

  /// Null when the move is allowed; a reason otherwise. Pure and total.
  ///
  /// [isCrew] is whether this person is rostered on *this* departure and
  /// [mayManage] whether they hold `departure.manage` — a dispatcher in an
  /// office closing a coach whose crew has no signal. Both are read by the
  /// caller; this function stays database-free.
  ///
  /// A move to the state it is already in is **not** a refusal. A driver
  /// tapping "we have left" twice on a bad connection means it once, the same
  /// rule the roster follows for a dispatcher who taps twice.
  static DepartureTransitionRefusal? transition({
    required DepartureState from,
    required DepartureState? to,
    required bool isCrew,
    required bool mayManage,
  }) {
    if (to == null) return DepartureTransitionRefusal.unknownState;
    if (!isCrew && !mayManage) return DepartureTransitionRefusal.notCrew;
    if (to == DepartureState.cancelled) {
      return DepartureTransitionRefusal.cancelIsADisruption;
    }

    if (from == to) return null;

    if (from == DepartureState.cancelled) {
      return DepartureTransitionRefusal.cancelled;
    }
    if (from.hasLeft && !(_next[from] ?? const {}).contains(to)) {
      return DepartureTransitionRefusal.alreadyClosed;
    }
    if (!(_next[from] ?? const {}).contains(to)) {
      return DepartureTransitionRefusal.outOfOrder;
    }
    return null;
  }

  /// Whether reaching [state] should stop new sales on this departure.
  ///
  /// **Sales, and nothing else.** A ticket already sold stays valid: a
  /// passenger who boarded and is sitting down has a valid ticket by
  /// definition, and a scan uploaded from a dead zone three hours after the
  /// coach left must still be accepted — the door happened while the coach
  /// was there.
  static bool closesSales(DepartureState state) => state.hasLeft;
}
