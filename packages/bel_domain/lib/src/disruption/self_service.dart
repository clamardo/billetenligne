/// The passenger's own choice (`08-disruption.md` §3.2).
///
/// The option most systems never build, and the argument for it is not
/// kindness: **a released seat goes back into the pool**. A dispatcher
/// assigning forty-two people to the seats they can see produces one plan;
/// forty-two people each taking the option that suits them frees seats the
/// dispatcher had already spent, and covers more of them. The screen is
/// cheaper than the coverage it buys.
///
/// Four rules the whole design hangs on, all of them in this file so that the
/// app and the server cannot disagree about them (ADR-0004):
///
///   * **A default is always already assigned.** Choice is an upgrade on a
///     safe state, never a prerequisite for one. A passenger who never opens
///     the message keeps a seat.
///   * **Every option carries its arrival time**, because that is what
///     somebody stranded actually cares about — not when the coach leaves.
///   * **There is a deadline and a stated fallback**, because ambiguity at
///     04:00 is worse than a rule somebody dislikes.
///   * **A full refund is always the last option and never hidden.** It is
///     the platform floor for an operator-caused disruption (ADR-0015 rule
///     4), so no policy can configure it away.
library;

import '../money/money.dart';
import '../shared/failure.dart';
import 'reaccommodation.dart';

/// What a passenger can do about a disrupted journey.
enum TravelChoiceKind {
  /// Keep what was already assigned — the rescue coach, or the departure the
  /// rebooking wave moved them onto.
  keep,

  /// Move to another departure they picked themselves.
  move,

  /// Take the money back instead.
  refund,
}

/// One row on the choice screen.
///
/// Carries what §3.2 says the row must show and nothing else: a passenger
/// deciding at a roadside reads three of these on a phone, and every field
/// that is not the decision is noise.
final class TravelChoice {
  const TravelChoice({
    required this.kind,
    required this.id,
    required this.assigned,
    this.departureId,
    this.operatorName,
    this.departsAt,
    this.arrivesAt,
    this.seatsAvailable,
    this.seatLabels = const [],
    this.amount,
    this.otherOperator = false,
  });

  final TravelChoiceKind kind;

  /// What the client sends back: a departure id, or `keep` / `refund`.
  final String id;

  /// Whether this is what the passenger already has. Exactly one option
  /// carries it, and it is the one that happens if they never answer.
  final bool assigned;

  final String? departureId;
  final String? operatorName;
  final DateTime? departsAt;

  /// **Shown on every travel option.** The passenger is asking when they get
  /// there, not when they leave.
  final DateTime? arrivesAt;

  /// Live, and only meaningful on an option somebody has not taken yet.
  final int? seatsAvailable;

  /// Where they are sitting, on the option they already hold.
  final List<String> seatLabels;

  /// What comes back, on the refund option.
  final Money? amount;

  /// A coach belonging to another company (§5). Said out loud on the row,
  /// because a passenger arriving at a gare looking for a coach with the
  /// wrong name on it is the failure this one word prevents.
  final bool otherOperator;

  bool get isRefund => kind == TravelChoiceKind.refund;
}

/// When the choice closes, and what happens then.
///
/// One hour before the assigned departure leaves. Not a fixed clock time:
/// the deadline exists so a conductor has a manifest that stops changing
/// while people are boarding, and that is measured from the coach, not from
/// the declaration.
///
/// Never in the past relative to [now] by more than the window itself — a
/// disruption declared forty minutes before a rescue coach leaves gives a
/// deadline that has already passed, and the honest answer there is that the
/// choice was never open rather than that it closed.
DateTime choiceDeadline({
  required DateTime assignedDepartsAt,
  Duration before = const Duration(hours: 1),
}) => assignedDepartsAt.subtract(before);

/// Why a passenger cannot choose, or cannot choose *that*.
sealed class ChoiceRefusal extends DomainFailure {
  const ChoiceRefusal();
}

/// Nothing is happening to this journey. Not an error the passenger caused —
/// most of the time it means a dispatcher resolved the disruption while the
/// screen was open.
final class NothingDisrupted extends ChoiceRefusal {
  const NothingDisrupted();
  @override
  String get code => 'choice.nothing_disrupted';
}

/// The deadline passed. The fallback already applies, and saying which one is
/// the whole point of having stated it in advance.
final class ChoiceWindowClosed extends ChoiceRefusal {
  const ChoiceWindowClosed();
  @override
  String get code => 'choice.window_closed';
}

/// The option is not one that was offered. A stale screen, usually: the
/// 14:00 sold out while somebody was reading.
final class UnknownChoice extends ChoiceRefusal {
  const UnknownChoice();
  @override
  String get code => 'choice.unknown_option';
}

/// The seats went while they were deciding. A real outcome, and the reason
/// the screen re-reads before it commits.
final class ChoiceNoLongerAvailable extends ChoiceRefusal {
  const ChoiceNoLongerAvailable();
  @override
  String get code => 'choice.no_longer_available';
}

/// A party of three cannot be split across two coaches to make the
/// arithmetic work — the same rule the dispatcher's wave follows, said to the
/// passenger who would otherwise be the one split.
final class PartyDoesNotFit extends ChoiceRefusal {
  const PartyDoesNotFit(this.seatsNeeded, this.seatsAvailable);
  final int seatsNeeded;
  final int seatsAvailable;
  @override
  String get code => 'choice.party_does_not_fit';
  @override
  Map<String, Object?> get params => {
    'seatsNeeded': seatsNeeded,
    'seatsAvailable': seatsAvailable,
  };
}

/// Whether this passenger may choose at all, and whether they may choose
/// this.
///
/// Called by the app before it draws the screen and by the server before it
/// moves anybody — the same function, so a row the app offers is a row the
/// server accepts (ADR-0004).
///
/// [choice] is null when the question is only "is the screen open".
ChoiceRefusal? refuseChoice({
  required bool involuntary,
  required bool disruptionOpen,
  required DateTime deadline,
  required DateTime now,
  TravelChoice? choice,
  int seatsNeeded = 1,
}) {
  // The entitlement is the exemption on the booking, not the disruption row.
  // A passenger moved by yesterday's wave still carries theirs; a passenger
  // who bought a seat on the replacement coach this morning does not, and
  // must not be offered a free refund because somebody else's coach failed.
  if (!involuntary || !disruptionOpen) return const NothingDisrupted();
  if (!now.isBefore(deadline)) return const ChoiceWindowClosed();

  if (choice == null) return null;

  // Keeping what you already have is always available while the window is
  // open, and needs no seats: they are already sitting in them.
  if (choice.assigned || choice.isRefund) return null;

  final free = choice.seatsAvailable ?? 0;
  if (free <= 0) return const ChoiceNoLongerAvailable();
  if (free < seatsNeeded) return PartyDoesNotFit(seatsNeeded, free);
  return null;
}

/// Whether a departure can appear on the choice screen at all.
///
/// The passenger's version of [refuseReplacement], and deliberately the same
/// rules: an option the server would refuse is worse than an option that was
/// never shown, because the passenger has already told somebody they have a
/// coach by the time they find out.
bool offerableToPassenger({
  required String departureId,
  required String currentDepartureId,
  required String routeId,
  required String candidateRouteId,
  required String candidateStatus,
  required DateTime departsAt,
  required DateTime candidateDepartsAt,
  required DateTime now,
  required int seatsAvailable,
  int seatsNeeded = 1,
}) {
  if (seatsAvailable < seatsNeeded) return false;
  return refuseReplacement(
        departureId: currentDepartureId,
        replacementId: departureId,
        routeId: routeId,
        replacementRouteId: candidateRouteId,
        replacementStatus: candidateStatus,
        // Measured from **now**, not from the broken departure's own time. A
        // coach that left at 06:00 and broke down at 09:00 can be replaced by
        // the 08:00, which is exactly the case a comparison against the
        // original departure time refuses for no reason anybody can explain
        // to the passenger standing there.
        departsAt: now,
        replacementDepartsAt: candidateDepartsAt,
        now: now,
      ) ==
      null;
}
