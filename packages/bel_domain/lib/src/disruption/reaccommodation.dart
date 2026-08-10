/// One booking, as the re-accommodation engine sees it.
///
/// A **party**, not a passenger: three people who booked together are one
/// unit here, because splitting a family across two departures to make the
/// arithmetic come out is not a solution anybody would accept at a counter.
final class PartyToMove {
  const PartyToMove({
    required this.bookingId,
    required this.seats,
    required this.bookedAt,
  });

  final String bookingId;

  /// How many seats this booking holds. Always at least one.
  final int seats;

  /// When the booking was made. The tie-breaker, and the only ordering a
  /// dispatcher can defend out loud: whoever booked first is moved first.
  final DateTime bookedAt;
}

/// Why a departure cannot be used as a replacement.
///
/// Every one of these is a fact about the two departures rather than about
/// the seats, so the engine can refuse before it locks anything.
sealed class RebookingRefusal {
  const RebookingRefusal();

  String get code;
}

/// The replacement is the departure being rescued.
final class SameDeparture extends RebookingRefusal {
  const SameDeparture();
  @override
  String get code => 'rebooking.same_departure';
}

/// A different road. Moving somebody from BZV–PNR onto BZV–Oyo is not a
/// re-accommodation, it is a different journey.
final class DifferentRoute extends RebookingRefusal {
  const DifferentRoute();
  @override
  String get code => 'rebooking.different_route';
}

/// A replacement that leaves before the one it replaces is a departure the
/// passengers cannot physically reach.
final class ReplacementNotLater extends RebookingRefusal {
  const ReplacementNotLater();
  @override
  String get code => 'rebooking.not_later';
}

/// The replacement is not on sale: cancelled, departed, or arrived. A coach
/// that is itself cancelled is not a re-accommodation.
final class ReplacementNotSellable extends RebookingRefusal {
  const ReplacementNotSellable();
  @override
  String get code => 'rebooking.not_sellable';
}

/// The replacement has already gone.
final class ReplacementHasLeft extends RebookingRefusal {
  const ReplacementHasLeft();
  @override
  String get code => 'rebooking.already_left';
}

/// Nobody to move: no confirmed booking on the departure.
final class NothingToMove extends RebookingRefusal {
  const NothingToMove();
  @override
  String get code => 'rebooking.nothing_to_move';
}

/// Not one party fits. Refused rather than reported as a wave that moved
/// nobody, because "0 / 42" dressed up as a success is how a dispatcher
/// walks away believing the problem is handled.
final class NobodyFits extends RebookingRefusal {
  const NobodyFits();
  @override
  String get code => 'rebooking.nobody_fits';
}

/// Who is moving, and who is not.
final class RebookingPlan {
  const RebookingPlan({required this.moved, required this.left});

  final List<PartyToMove> moved;

  /// The parties still on the broken departure. **Named, never dropped.**
  /// Partial coverage is the normal outcome of §2.2 option ②, and a
  /// dispatcher combining a later departure with a rescue coach to cover
  /// everybody needs to know exactly who is still uncovered.
  final List<PartyToMove> left;

  int get passengersMoved =>
      moved.fold(0, (total, party) => total + party.seats);

  int get passengersLeft => left.fold(0, (total, party) => total + party.seats);

  int get passengersTotal => passengersMoved + passengersLeft;

  bool get coversEverybody => left.isEmpty;
}

/// Whether one departure can stand in for another.
///
/// Checked before anything is locked, and by the domain rather than by a
/// copy of the rules in an adapter (ADR-0004): the console asks the same
/// question when it decides which departures to even offer.
RebookingRefusal? refuseReplacement({
  required String departureId,
  required String replacementId,
  required String routeId,
  required String replacementRouteId,
  required String replacementStatus,
  required DateTime departsAt,
  required DateTime replacementDepartsAt,
  required DateTime now,
}) {
  if (departureId == replacementId) return const SameDeparture();
  if (routeId != replacementRouteId) return const DifferentRoute();
  if (!sellableDepartureStatuses.contains(replacementStatus)) {
    return const ReplacementNotSellable();
  }
  if (!replacementDepartsAt.isAfter(departsAt)) {
    return const ReplacementNotLater();
  }
  if (!replacementDepartsAt.isAfter(now)) return const ReplacementHasLeft();
  return null;
}

/// The departure statuses a replacement may be in.
///
/// `delayed` is here on purpose: a coach running an hour late is still a
/// coach, and refusing to move somebody onto it because it has its own
/// problem would leave them with none at all.
const sellableDepartureStatuses = {'scheduled', 'delayed', 'boarding'};

/// Fits as many parties as possible into the seats a replacement has left.
///
/// **First fit, in booking order.** Two properties, and both are about the
/// conversation at the counter afterwards rather than about the arithmetic:
///
///   * A party that does not fit is skipped and the next one is tried, so a
///     family of four blocking the last three seats does not strand the
///     eleven single travellers behind them.
///   * The order is the order people booked in. It is the only rule a
///     dispatcher can say out loud to somebody who was left behind — sorting
///     by party size would cover more people and would mean explaining to a
///     family why the person who booked after them is on the coach.
RebookingPlan allocateRebooking({
  required List<PartyToMove> parties,
  required int seatsAvailable,
}) {
  final queue = [...parties]..sort((a, b) => a.bookedAt.compareTo(b.bookedAt));

  final moved = <PartyToMove>[];
  final left = <PartyToMove>[];
  var remaining = seatsAvailable;

  for (final party in queue) {
    if (party.seats <= remaining) {
      moved.add(party);
      remaining -= party.seats;
    } else {
      left.add(party);
    }
  }

  return RebookingPlan(moved: moved, left: left);
}
