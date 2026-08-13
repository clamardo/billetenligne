import 'package:bel_domain/bel_domain.dart';

/// A request to claim specific seats, already validated by the use case.
///
/// Everything a claim needs, decided before the database is touched. The
/// transaction inside the adapter should be as short as physically possible:
/// every microsecond a row lock is held is a microsecond another traveller
/// spends watching a spinner during the 06:00 rush.
final class SeatClaim {
  const SeatClaim({
    required this.departureId,
    required this.seatLabels,
    required this.userId,
    required this.ttl,
    required this.idempotencyKey,
    this.channel = 'app',
    this.fromCity,
    this.toCity,
  });

  final String departureId;

  /// The pair the traveller searched with, when they are buying a **piece** of
  /// the road (ADR-0025). Both or neither.
  ///
  /// City codes rather than positions, for the same reason the seat map takes
  /// them: a position is an index into a road the client does not own, and a
  /// client that could send one could send a journey the operator never put
  /// on sale. The adapter resolves them against the departure's own road and
  /// against what the operator has priced.
  final String? fromCity;
  final String? toCity;

  /// Sorted by the use case before it gets here. Two travellers asking for
  /// {12A, 12B} and {12B, 12A} must lock the rows in the SAME order or they
  /// deadlock each other — and the one that loses gets a Postgres error
  /// instead of a seat map.
  final List<String> seatLabels;

  final String userId;

  /// How long the hold should last — not *when* it should end.
  ///
  /// The expiry instant is computed by the database, and the answer comes back
  /// on [SeatsClaimed.expiresAt]. Two API instances with a few seconds of
  /// clock skew must never disagree about who owns seat 12A, and the only
  /// clock all of them share is Postgres's.
  final Duration ttl;

  final String idempotencyKey;

  /// `app` | `console` | `agency`. A cash sale at the counter takes this same
  /// path, which is exactly what makes agent and digital sales reconcile.
  final String channel;
}

/// What happened when we tried.
sealed class ClaimOutcome {
  const ClaimOutcome();
}

/// The seats are ours for [expiresAt].
final class SeatsClaimed extends ClaimOutcome {
  const SeatsClaimed({
    required this.holdId,
    required this.operatorId,
    required this.seatLabels,
    required this.fare,
    required this.expiresAt,
    this.replayed = false,
  });

  final String holdId;
  final String operatorId;
  final List<String> seatLabels;

  /// Sum of the per-seat fares actually on the rows we locked — never a fare
  /// the client sent us, and never one re-derived from the departure. A seat
  /// can carry its own price (front row, VIP section), and the row is the
  /// only thing that knows.
  final Money fare;

  final DateTime expiresAt;

  /// True when this key had already produced this hold. The response is
  /// identical either way; the flag exists so support can tell "asked twice"
  /// from "held twice".
  final bool replayed;
}

/// Someone else got there first. Names the seats so the app can grey exactly
/// those and leave the rest of the map alone.
final class SeatsTaken extends ClaimOutcome {
  const SeatsTaken(this.seatLabels);
  final List<String> seatLabels;
}

/// This idempotency key already belongs to a different traveller's hold.
///
/// Not a race and not a retry — a client bug or someone probing. Worth its own
/// answer rather than being folded into "seat taken", which would send an
/// honest client hunting for a seat that was never the problem.
final class IdempotencyKeyTaken extends ClaimOutcome {
  const IdempotencyKeyTaken();
}

/// The seats do not exist on this departure. A stale seat map, usually — the
/// operator swapped a 70-seat coach for a 51-seat one after a breakdown.
final class SeatsUnknown extends ClaimOutcome {
  const SeatsUnknown(this.seatLabels);
  final List<String> seatLabels;
}

/// The two towns are not a journey this operator sells.
///
/// Distinct from a full coach and from a departure that has left: nothing is
/// wrong with the coach, and nothing will change by retrying. Either the
/// operator has not priced that leg, or the road does not run between those
/// two towns in that direction at all.
final class SegmentNotOnSale extends ClaimOutcome {
  const SegmentNotOnSale(this.fromCity, this.toCity);
  final String fromCity;
  final String toCity;
}

/// The departure cannot be sold right now.
final class DepartureNotSellable extends ClaimOutcome {
  const DepartureNotSellable(this.reason);

  /// One of [missing], [cancelled], [gone], [salesClosed].
  final String reason;

  static const missing = 'missing';
  static const cancelled = 'cancelled';

  /// Already departed or arrived. Nobody is boarding this one.
  static const gone = 'gone';

  /// The operator closes sales some minutes before departure so the manifest
  /// can be printed and the conductor is not handed a passenger who bought a
  /// seat while the coach was pulling out.
  static const salesClosed = 'sales_closed';

  /// The operator is not selling: a compliance document lapsed and the
  /// expiry ladder stopped new sales, or they are suspended
  /// (03-operator-lifecycle.md §3.3, §4). Every ticket already sold is
  /// untouched and the coach still runs — this refuses the *sale*, not the
  /// departure.
  static const operatorBlocked = 'operator_blocked';
}

/// Claims and releases seats atomically.
///
/// Atomicity is the adapter's problem, not the use case's — which is why this
/// port exposes no transaction, no session and no connection. A use case that
/// could see a transaction handle would eventually be tempted to hold one open
/// across a network call to a mobile money gateway, and that is how a database
/// falls over at 06:00 (ADR-0012).
abstract interface class SeatInventory {
  Future<ClaimOutcome> claim(SeatClaim claim);

  /// The traveller backed out of the payment screen. Idempotent, and scoped to
  /// the owner: releasing someone else's hold must be impossible even if the
  /// id leaks.
  Future<bool> release({required String holdId, required String userId});

  /// Returns held seats whose expiry has passed. Called by the sweeper, but
  /// **never relied upon alone**: [claim] also treats an expired hold as
  /// available, so a stalled worker cannot leak inventory.
  Future<int> sweepExpired(DateTime now, {int limit = 500});
}
