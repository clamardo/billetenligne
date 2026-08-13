import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/departure_catalogue.dart';
import '../../application/ports/seat_inventory.dart';

/// A departure's worth of seats, in memory.
final class MemoryDeparture {
  MemoryDeparture({
    required this.id,
    required this.operatorId,
    required this.departsAt,
    required Iterable<String> seatLabels,
    this.operatorName = 'Ocean du Nord',
    this.originCity = 'BZV',
    this.destinationCity = 'PNR',
    this.mode = 'bus',
    this.accentHue = 'foret',
    this.amenities = const ['wifi', 'usb', 'ac'],
    this.duration = const Duration(hours: 8),
    this.fare = const Money.xaf(12000),
    this.status = 'scheduled',
    this.salesCloseAt,
  }) : seats = {for (final label in seatLabels) label: _Seat(fare)};

  final String id;
  final String operatorId;
  final String operatorName;
  final String originCity;
  final String destinationCity;
  final String mode;
  final String accentHue;
  final List<String> amenities;
  final Duration duration;
  final DateTime departsAt;
  final Money fare;
  final String status;
  final DateTime? salesCloseAt;
  final Map<String, _Seat> seats;

  DateTime get arrivesAt => departsAt.add(duration);
  int get capacity => seats.length;

  /// A 2+2 coach: rows of A, B, C, D.
  factory MemoryDeparture.coach({
    required String id,
    required String operatorId,
    required DateTime departsAt,
    int rows = 13,
    Money fare = const Money.xaf(12000),
    String status = 'scheduled',
    String operatorName = 'Ocean du Nord',
    String originCity = 'BZV',
    String destinationCity = 'PNR',
  }) => MemoryDeparture(
    id: id,
    operatorId: operatorId,
    departsAt: departsAt,
    fare: fare,
    status: status,
    operatorName: operatorName,
    originCity: originCity,
    destinationCity: destinationCity,
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

  Iterable<MemoryDeparture> get departures => _departures.values;

  /// What the catalogue sees: a lapsed hold reads as available, exactly as it
  /// does in SQL.
  String seatStateAt(MemoryDeparture departure, String label, DateTime now) {
    final seat = departure.seats[label]!;
    final lapsed = seat.heldUntil != null && !seat.heldUntil!.isAfter(now);
    return seat.state == 'held' && lapsed ? 'available' : seat.state;
  }

  Money seatFare(MemoryDeparture departure, String label) =>
      departure.seats[label]!.fare;

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

    // The demo world runs no roads with stops on them, so it has no legs to
    // price. A pair that is this coach's own two ends is the ordinary
    // whole-journey claim; anything else is a journey nobody here sells, and
    // selling it at the through fare would be the one lie this file is not
    // allowed to tell (ADR-0025).
    if (claim.fromCity != null &&
        (claim.fromCity != departure.originCity ||
            claim.toCity != departure.destinationCity)) {
      return SegmentNotOnSale(claim.fromCity!, claim.toCity!);
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

  /// A read-only view of a hold, for the pieces that need to know what was
  /// claimed without being able to change it.
  ///
  /// A record rather than the private class: exposing `_MemoryHold` would let
  /// a caller mutate inventory state through a getter, and the Postgres
  /// adapter offers no such thing — a fake that is more capable than the real
  /// adapter is a fake that lets tests pass on code that cannot ship.
  ({
    String id,
    String userId,
    String departureId,
    String operatorId,
    List<String> seatLabels,
    DateTime expiresAt,
    String state,
  })?
  holdView(String holdId) {
    final hold = _holds[holdId];
    if (hold == null) return null;
    return (
      id: hold.id,
      userId: hold.userId,
      departureId: hold.departureId,
      operatorId: hold.operatorId,
      seatLabels: List.unmodifiable(hold.seatLabels),
      expiresAt: hold.expiresAt,
      state: hold.state,
    );
  }

  /// The fare on one seat row. The fake's equivalent of the real adapter's
  /// in-transaction price read, so both price from inventory rather than from
  /// whatever the caller passed.
  Money? fareFor(String departureId, String seatLabel) =>
      _departures[departureId]?.seats[seatLabel]?.fare;

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

/// The catalogue, without a database.
///
/// Reads the same [MemorySeatInventory] the holds are written to, so a seat
/// that has just been held disappears from the seat map here exactly as it
/// would in SQL. A fake that answered from a separate store would be a fake
/// that lies about the one thing this screen is for.
final class MemoryDepartureCatalogue implements DepartureCatalogue {
  const MemoryDepartureCatalogue(this._inventory, {required Clock clock})
    : _clock = clock;

  final MemorySeatInventory _inventory;
  final Clock _clock;

  @override
  Future<List<DepartureRow>> search(DepartureQuery query) async {
    final now = _clock.now();

    final matches =
        _inventory.departures.where((d) {
          if (d.originCity != query.originCity) return false;
          if (d.destinationCity != query.destinationCity) return false;
          if (d.status == 'cancelled') return false;
          if (!d.departsAt.isAfter(now)) return false;
          if (query.operatorId != null && d.operatorId != query.operatorId) {
            return false;
          }
          if (query.mode != null && d.mode != query.mode) return false;
          if (query.after case final after?) {
            // The same strict ordering the SQL uses, and it has to be the same:
            // a fake that paged differently would let a bug through that only
            // ever shows up against Postgres.
            final byTime = d.departsAt.compareTo(after.departsAt);
            if (byTime < 0 || (byTime == 0 && d.id.compareTo(after.id) <= 0)) {
              return false;
            }
          }
          return _isSameLocalDay(d.departsAt, query.localDate);
        }).toList()..sort((a, b) {
          final byTime = a.departsAt.compareTo(b.departsAt);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });

    return [
      for (final d in matches.take(query.limit))
        DepartureRow(
          id: d.id,
          operatorId: d.operatorId,
          operatorName: d.operatorName,
          mode: d.mode,
          originCity: d.originCity,
          destinationCity: d.destinationCity,
          departsAt: d.departsAt,
          arrivesAt: d.arrivesAt,
          fare: d.fare,
          seatsAvailable: d.seats.keys
              .where((l) => _inventory.seatStateAt(d, l, now) == 'available')
              .length,
          capacity: d.capacity,
          seatSelectionEnabled: true,
          operatorAccentHue: d.accentHue,
          amenities: d.amenities,
        ),
    ];
  }

  @override
  Future<SeatMapDto?> seatMap(
    String departureId, {
    String? fromCity,
    String? toCity,
  }) async {
    final departure = _inventory.departure(departureId);
    if (departure == null) return null;
    // The pair is handed back by the client unchanged, so on a whole journey
    // it is this coach's own two ends and means nothing. The demo world has
    // no roads with stops on them, so it has no legs to price either — and
    // answering a leg question with a whole-road seat map is the one lie this
    // file is not allowed to tell (ADR-0025).
    if (fromCity != null &&
        (fromCity != departure.originCity ||
            toCity != departure.destinationCity)) {
      return null;
    }

    final now = _clock.now();
    final labels = departure.seats.keys.toList()..sort();

    return SeatMapDto(
      departureId: departureId,
      mode: departure.mode,
      layoutVersion: 1,
      sections: [
        CabinSectionDto(
          code: 'STD',
          labelKey: 'seat.class.standard',
          rows: (labels.length / 4).ceil(),
          abreast: '2+2',
        ),
      ],
      seats: [
        for (final label in labels)
          SeatDto(
            label: label,
            sectionCode: 'STD',
            fare: _inventory.seatFare(departure, label),
            status: switch (_inventory.seatStateAt(departure, label, now)) {
              'held' => SeatStatusDto.held,
              'sold' => SeatStatusDto.sold,
              'blocked' => SeatStatusDto.blocked,
              _ => SeatStatusDto.available,
            },
          ),
      ],
    );
  }

  /// Compared in UTC, which is a simplification the Postgres adapter does not
  /// make. Fine here: the fakes exist so a fresh clone answers something, and
  /// the timezone question is tested where it is actually decided.
  static bool _isSameLocalDay(DateTime instant, DateTime date) =>
      instant.year == date.year &&
      instant.month == date.month &&
      instant.day == date.day;
}
