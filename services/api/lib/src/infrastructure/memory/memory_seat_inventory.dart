import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/seat_inventory.dart';

/// A departure's worth of seats, in memory.
final class MemoryDeparture {
  MemoryDeparture({
    required this.id,
    required this.operatorId,
    required this.departsAt,
    required Iterable<String> seatLabels,
    this.fare = const Money.xaf(12000),
    this.status = 'scheduled',
    this.salesCloseAt,
  }) : seats = {for (final label in seatLabels) label: _Seat(fare)};

  final String id;
  final String operatorId;
  final DateTime departsAt;
  final Money fare;
  final String status;
  final DateTime? salesCloseAt;
  final Map<String, _Seat> seats;

  /// A 2+2 coach: rows of A, B, C, D.
  factory MemoryDeparture.coach({
    required String id,
    required String operatorId,
    required DateTime departsAt,
    int rows = 13,
    Money fare = const Money.xaf(12000),
    String status = 'scheduled',
  }) => MemoryDeparture(
    id: id,
    operatorId: operatorId,
    departsAt: departsAt,
    fare: fare,
    status: status,
    seatLabels: [
      for (var row = 1; row <= rows; row++)
        for (final col in const ['A', 'B', 'C', 'D']) '$row$col',
    ],
  );
}

final class _Seat {
  _Seat(this.fare);
  final Money fare;
  String state = 'available';
  String? holdId;
  DateTime? heldUntil;
}

final class _MemoryHold {
  _MemoryHold({
    required this.id,
    required this.userId,
    required this.departureId,
    required this.operatorId,
    required this.seatLabels,
    required this.expiresAt,
    required this.fare,
  });

  final String id;
  final String userId;
  final String departureId;
  final String operatorId;
  final List<String> seatLabels;
  final DateTime expiresAt;
  final Money fare;
  String state = 'active';
}

/// The seat inventory, without a database.
///
/// Exists for two reasons, and only those two:
///
///   * `dart_frog dev` and `tool/smoke_api.sh` run with no Postgres, so the
///     API is usable the moment somebody clones the repo;
///   * the [HoldSeats] use case gets unit tests that run in milliseconds.
///
/// It is **not** a substitute for the Postgres adapter's tests. Nothing here
/// can prove that fifty concurrent claims produce one winner, because there is
/// no concurrency to lose to — that proof lives in `hold_seats_pg_test.dart`
/// and needs a real database to mean anything.
final class MemorySeatInventory implements SeatInventory {
  MemorySeatInventory({
    required Clock clock,
    List<MemoryDeparture> departures = const [],
  }) : _clock = clock {
    for (final d in departures) {
      _departures[d.id] = d;
    }
  }

  final Clock _clock;
  final Map<String, MemoryDeparture> _departures = {};
  final Map<String, _MemoryHold> _holds = {};
  final Map<String, String> _holdsByKey = {};
  var _counter = 0;

  void add(MemoryDeparture departure) => _departures[departure.id] = departure;

  MemoryDeparture? departure(String id) => _departures[id];

  @override
  Future<ClaimOutcome> claim(SeatClaim claim) async {
    final now = _clock.now();

    final existingId = _holdsByKey[claim.idempotencyKey];
    if (existingId != null) {
      final hold = _holds[existingId]!;
      if (hold.userId != claim.userId) return const IdempotencyKeyTaken();
      if (hold.state == 'active') {
        return SeatsClaimed(
          holdId: hold.id,
          operatorId: hold.operatorId,
          seatLabels: hold.seatLabels,
          fare: hold.fare,
          expiresAt: hold.expiresAt,
          replayed: true,
        );
      }
    }

    final departure = _departures[claim.departureId];
    if (departure == null) {
      return const DepartureNotSellable(DepartureNotSellable.missing);
    }
    if (departure.status == 'cancelled') {
      return const DepartureNotSellable(DepartureNotSellable.cancelled);
    }
    if (!departure.departsAt.isAfter(now)) {
      return const DepartureNotSellable(DepartureNotSellable.gone);
    }
    final closesAt = departure.salesCloseAt;
    if (closesAt != null && !closesAt.isAfter(now)) {
      return const DepartureNotSellable(DepartureNotSellable.salesClosed);
    }

    final unknown = [
      for (final label in claim.seatLabels)
        if (!departure.seats.containsKey(label)) label,
    ];
    if (unknown.isNotEmpty) return SeatsUnknown(unknown);

    final taken = <String>[];
    for (final label in claim.seatLabels) {
      final seat = departure.seats[label]!;
      final lapsed = seat.heldUntil != null && !seat.heldUntil!.isAfter(now);
      final live = switch (seat.state) {
        'sold' || 'blocked' => true,
        'held' => !lapsed,
        _ => false,
      };
      if (live) taken.add(label);
    }
    if (taken.isNotEmpty) return SeatsTaken(taken..sort());

    final holdId = 'hold-${++_counter}';
    final expiresAt = now.add(claim.ttl);
    var fareMinor = 0;
    Currency? currency;

    for (final label in claim.seatLabels) {
      final seat = departure.seats[label]!
        ..state = 'held'
        ..holdId = holdId
        ..heldUntil = expiresAt;
      fareMinor += seat.fare.minor;
      currency ??= seat.fare.currency;
    }

    final hold = _MemoryHold(
      id: holdId,
      userId: claim.userId,
      departureId: claim.departureId,
      operatorId: departure.operatorId,
      seatLabels: claim.seatLabels,
      expiresAt: expiresAt,
      fare: Money(fareMinor, currency ?? Currency.xaf),
    );
    _holds[holdId] = hold;
    _holdsByKey[claim.idempotencyKey] = holdId;

    return SeatsClaimed(
      holdId: holdId,
      operatorId: departure.operatorId,
      seatLabels: claim.seatLabels,
      fare: hold.fare,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<bool> release({required String holdId, required String userId}) async {
    final hold = _holds[holdId];
    if (hold == null || hold.userId != userId || hold.state != 'active') {
      return false;
    }
    hold.state = 'released';

    final departure = _departures[hold.departureId];
    for (final label in hold.seatLabels) {
      final seat = departure?.seats[label];
      if (seat == null || seat.holdId != holdId) continue;
      seat
        ..state = 'available'
        ..holdId = null
        ..heldUntil = null;
    }
    return true;
  }

  @override
  Future<int> sweepExpired(DateTime now, {int limit = 500}) async {
    var swept = 0;
    for (final hold in _holds.values) {
      if (hold.state != 'active' || hold.expiresAt.isAfter(now)) continue;
      if (swept >= limit) break;
      hold.state = 'expired';
      final departure = _departures[hold.departureId];
      for (final label in hold.seatLabels) {
        final seat = departure?.seats[label];
        if (seat == null || seat.holdId != hold.id) continue;
        seat
          ..state = 'available'
          ..holdId = null
          ..heldUntil = null;
        swept++;
      }
    }
    return swept;
  }
}
