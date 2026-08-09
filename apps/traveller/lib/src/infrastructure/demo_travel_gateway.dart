import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/travel_gateway.dart';

/// A coach and a timetable, with no server.
///
/// Exists so the app runs on a fresh clone and in a widget test: `flutter run`
/// with no API reachable still shows a working funnel, which is what makes the
/// screens reviewable by somebody who is not set up to run Postgres.
///
/// It holds seats for real — the same seat cannot be taken twice — so the
/// interesting failure on the seat map is reachable without a network.
final class DemoTravelGateway implements TravelGateway {
  DemoTravelGateway({DateTime? now}) : _now = now ?? DateTime.now().toUtc() {
    _seed();
  }

  final DateTime _now;
  final _departures = <String, DepartureSummaryDto>{};
  final _seats = <String, List<SeatDto>>{};
  final _holds = <String, HoldDto>{};
  var _counter = 0;

  /// Delay before every answer. Not decoration: a screen that renders
  /// instantly in development hides every loading state it has, and those are
  /// the states that actually ship to somebody on 2G.
  Duration latency = const Duration(milliseconds: 350);

  void _seed() {
    const operators = [
      ('op-odn', 'Ocean du Nord', 'foret'),
      ('op-tbv', 'Trans Bony Voyages', 'laterite'),
      ('op-mvt', 'Mavita Transport', 'indigo'),
    ];

    for (var i = 0; i < 4; i++) {
      final (operatorId, name, hue) = operators[i % operators.length];
      final departsAt = DateTime.utc(
        _now.year,
        _now.month,
        _now.day,
      ).add(Duration(days: 1, hours: 6 + i * 4));

      final id = 'demo-dep-${i + 1}';
      // The last one is nearly full, so "almost full" and "sold out" are both
      // reachable without waiting for real traffic.
      final taken = i == 3 ? 50 : i * 6;

      _departures[id] = DepartureSummaryDto(
        id: id,
        operatorId: operatorId,
        operatorName: name,
        mode: 'bus',
        originCity: 'BZV',
        destinationCity: 'PNR',
        departsAt: departsAt,
        arrivesAt: departsAt.add(const Duration(hours: 8)),
        fare: Money.xaf(12000 + i * 1500),
        serviceFee: Market.current.serviceFee,
        seatsAvailable: 52 - taken,
        capacity: 52,
        seatSelectionEnabled: true,
        operatorAccentHue: hue,
        amenities: const ['wifi', 'usb', 'ac'],
        onTimeRate: 88 - i * 3,
      );

      _seats[id] = [
        for (var row = 1; row <= 13; row++)
          for (final col in const ['A', 'B', 'C', 'D'])
            SeatDto(
              label: '$row$col',
              sectionCode: 'STD',
              status: ((row - 1) * 4 + 'ABCD'.indexOf(col)) < taken
                  ? SeatStatusDto.sold
                  : SeatStatusDto.available,
              fare: Money.xaf(12000 + i * 1500),
            ),
      ];
    }
  }

  /// The same six the API's fakes composition serves. Congo's intercity
  /// network is genuinely this small.
  @override
  Future<List<CityDto>> cities() async {
    await Future<void>.delayed(latency);
    return const [
      CityDto(code: 'BZV', name: 'Brazzaville'),
      CityDto(code: 'PNR', name: 'Pointe-Noire'),
      CityDto(code: 'DLS', name: 'Dolisie'),
      CityDto(code: 'NKY', name: 'Nkayi'),
      CityDto(code: 'OWE', name: 'Owando'),
      CityDto(code: 'OYO', name: 'Oyo'),
    ];
  }

  @override
  Future<List<DepartureSummaryDto>> search(SearchDeparturesQuery query) async {
    await Future<void>.delayed(latency);

    if (query.originCity == query.destinationCity) {
      throw const ServerRefused(400, ApiError(code: ErrorCode.badRequest));
    }

    return _departures.values
        .where((d) => d.originCity == query.originCity)
        .where((d) => d.destinationCity == query.destinationCity)
        .toList()
      ..sort((a, b) => a.departsAt.compareTo(b.departsAt));
  }

  @override
  Future<SeatMapDto> seatMap(String departureId) async {
    await Future<void>.delayed(latency);

    final seats = _seats[departureId];
    if (seats == null) {
      throw const ServerRefused(404, ApiError(code: ErrorCode.notFound));
    }

    return SeatMapDto(
      departureId: departureId,
      mode: 'bus',
      layoutVersion: 1,
      sections: const [
        CabinSectionDto(
          code: 'STD',
          labelKey: 'seat.class.standard',
          rows: 13,
          abreast: '2+2',
        ),
      ],
      seats: List.of(seats),
    );
  }

  @override
  Future<HoldDto> hold({
    required String departureId,
    required List<String> seatLabels,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(latency);

    // The same key twice returns the same hold, exactly as the server does.
    final existing = _holds[idempotencyKey];
    if (existing != null) return existing;

    final seats = _seats[departureId]!;
    final taken = [
      for (final label in seatLabels)
        if (seats.firstWhere((s) => s.label == label).status !=
            SeatStatusDto.available)
          label,
    ];
    if (taken.isNotEmpty) {
      throw ServerRefused(
        409,
        ApiError(
          code: ErrorCode.seatUnavailable,
          params: {'seats': taken.join(', ')},
        ),
      );
    }

    var fare = 0;
    for (final label in seatLabels) {
      final index = seats.indexWhere((s) => s.label == label);
      fare += seats[index].fare?.minor ?? 0;
      seats[index] = SeatDto(
        label: label,
        sectionCode: seats[index].sectionCode,
        status: SeatStatusDto.held,
        fare: seats[index].fare,
      );
    }

    final departure = _departures[departureId]!;
    final hold = HoldDto(
      id: 'demo-hold-${++_counter}',
      departureId: departureId,
      seatLabels: seatLabels,
      // Short in the demo so the countdown and its expiry are both reachable
      // in a sitting rather than only in theory.
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
      fare: Money.xaf(fare),
      serviceFee: departure.serviceFee,
      total: Money.xaf(fare) + departure.serviceFee,
      state: 'active',
    );

    _holds[idempotencyKey] = hold;
    return hold;
  }

  @override
  Future<void> release(String holdId) async {
    await Future<void>.delayed(latency);

    final key = _holds.entries
        .where((e) => e.value.id == holdId)
        .map((e) => e.key)
        .firstOrNull;
    if (key == null) return;

    final hold = _holds.remove(key)!;
    final seats = _seats[hold.departureId]!;
    for (final label in hold.seatLabels) {
      final index = seats.indexWhere((s) => s.label == label);
      seats[index] = SeatDto(
        label: label,
        sectionCode: seats[index].sectionCode,
        status: SeatStatusDto.available,
        fare: seats[index].fare,
      );
    }
  }
}
