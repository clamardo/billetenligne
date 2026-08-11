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
  Future<BookingDto> reserve({
    required String holdId,
    required List<PassengerDto> passengers,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(latency);

    // Looked up by hold id, and the map is keyed by idempotency key — the
    // same lookup `release` already does by hand. Getting this wrong reads as
    // "the hold expired", which is the most plausible-looking wrong answer
    // this gateway could give.
    final hold = _holds.values.where((h) => h.id == holdId).firstOrNull;
    if (hold == null) {
      throw const ServerRefused(410, ApiError(code: ErrorCode.holdExpired));
    }

    final departure = _departures[hold.departureId]!;
    // Priced from the hold, which was priced from the seats. Nothing here
    // takes a number from the caller, mirroring the real path.
    final fare = hold.fare;
    final fee = Money(
      departure.serviceFee.minor * hold.seatLabels.length,
      departure.fare.currency,
    );

    // A fixed code, printed on the screen's own hint in the demo: there is no
    // agency to walk into here, and a random one would make the flow
    // unreviewable.
    return _booking = BookingDto(
      id: 'bk-demo-${++_counter}',
      ref: 'BEL-DEMO$_counter',
      state: 'pending_payment',
      departureId: hold.departureId,
      operatorName: departure.operatorName,
      originCity: departure.originCity,
      destinationCity: departure.destinationCity,
      departsAt: departure.departsAt,
      arrivesAt: departure.arrivesAt,
      passengers: passengers,
      fare: fare,
      serviceFee: fee,
      total: fare + fee,
      createdAt: _now,
      paymentCode: 'K4M2Q',
      paymentDeadline: _now.add(const Duration(hours: 4)),
    );
  }

  // ── Paying ────────────────────────────────────────────────────────────────
  //
  // A demo rail that behaves like a real one: the prompt takes a few seconds
  // to be answered, and one number always declines. The states people never
  // see in development are the ones that ship broken, so the failure path is
  // reachable here without a test harness.

  BookingDto? _booking;
  PaymentIntentDto? _intent;
  var _polls = 0;

  /// Type this to watch the decline screen.
  static const decliningMsisdn = '060000000';

  @override
  Future<BookingDto> booking(String bookingId) async {
    await Future<void>.delayed(latency);
    return _booking!;
  }

  @override
  Future<List<BookingDto>> bookings() async {
    await Future<void>.delayed(latency);
    // A paid trip already in the list, so demo mode reaches the ticket — QR,
    // rotating code and all — without anybody having to walk the funnel and
    // pay first. The states nobody sees in development are the ones that ship
    // broken.
    return [if (_booking != null) _booking!, _disruptedTrip, _pastTrip];
  }

  /// A trip that is being disrupted right now, so the choice screen
  /// (`08-disruption.md` §3.2) is reachable in demo mode without a dispatcher
  /// and a broken coach. The states nobody sees in development are the ones
  /// that ship broken, and this one is a screen somebody reads at 04:00.
  static const disruptedRef = 'BEL-7QK4M2';

  BookingDto? _disrupted;
  String _choice = 'keep';

  BookingDto get _disruptedTrip {
    final leaves = DateTime.now().toUtc().add(const Duration(hours: 5));
    return _disrupted ??= _paid(
      BookingDto(
        id: 'bk-demo-disrupted',
        ref: disruptedRef,
        state: 'confirmed',
        departureId: 'dep-demo-rescue',
        operatorName: 'Ocean du Nord',
        originCity: 'Brazzaville',
        destinationCity: 'Pointe-Noire',
        departsAt: leaves,
        arrivesAt: leaves.add(const Duration(hours: 7, minutes: 30)),
        passengers: const [
          PassengerDto(fullName: 'Aline Massamba', seatLabel: '14A'),
        ],
        fare: const Money.xaf(9000),
        serviceFee: const Money.xaf(300),
        total: const Money.xaf(9300),
        createdAt: leaves.subtract(const Duration(days: 3)),
        involuntaryChange: true,
        disruption: DisruptionDto(
          id: 'dsr-demo',
          kind: DisruptionKind.breakdownEnRoute,
          cause: DisruptionCause.mechanical,
          declaredAt: DateTime.now().toUtc(),
          marksInvoluntary: true,
          location: 'Dolisie',
          note: 'Panne moteur. Un car de secours part a 11h30.',
        ),
      ),
    );
  }

  @override
  Future<TravelChoicesDto> travelOptions(String bookingRef) async {
    await Future<void>.delayed(latency);
    final trip = _disruptedTrip;
    final later = trip.departsAt.add(const Duration(hours: 3));

    return TravelChoicesDto(
      bookingRef: trip.ref,
      // The order §3.2 asks for: the safe state first, the alternatives, then
      // the refund — last and never hidden.
      options: [
        TravelChoiceDto(
          id: 'keep',
          kind: 'keep',
          assigned: _choice == 'keep',
          departureId: trip.departureId,
          operatorName: trip.operatorName,
          departsAt: trip.departsAt,
          arrivesAt: trip.arrivesAt,
          seatLabels: const ['14A'],
        ),
        TravelChoiceDto(
          id: 'dep-demo-later',
          kind: 'move',
          assigned: _choice == 'dep-demo-later',
          departureId: 'dep-demo-later',
          operatorName: trip.operatorName,
          departsAt: later,
          arrivesAt: later.add(const Duration(hours: 7, minutes: 30)),
          seatsAvailable: 18,
        ),
        TravelChoiceDto(
          id: 'refund',
          kind: 'refund',
          assigned: false,
          amount: trip.total,
        ),
      ],
      deadline: trip.departsAt.subtract(const Duration(hours: 1)),
      seatsNeeded: 1,
      originCity: trip.originCity,
      destinationCity: trip.destinationCity,
      open: true,
      disruptionKind: 'breakdownEnRoute',
      reasonKey: 'disruption.kind.breakdownEnRoute',
      note: trip.disruption?.note,
    );
  }

  @override
  Future<ChoiceAppliedDto> chooseTravel({
    required String bookingRef,
    required String optionId,
  }) async {
    await Future<void>.delayed(latency);
    _choice = optionId;

    if (optionId == 'refund') {
      return ChoiceAppliedDto(
        bookingRef: bookingRef,
        kind: 'refund',
        refunded: const Money.xaf(9300),
        claimCode: 'K7M2QRTV',
      );
    }

    final trip = _disruptedTrip;
    return ChoiceAppliedDto(
      bookingRef: bookingRef,
      kind: optionId == 'keep' ? 'keep' : 'move',
      departureId: optionId == 'keep' ? trip.departureId : optionId,
      departsAt: optionId == 'keep'
          ? trip.departsAt
          : trip.departsAt.add(const Duration(hours: 3)),
      seatLabels: const ['14A'],
    );
  }

  static BookingDto get _pastTrip {
    final departed = DateTime.now().toUtc().subtract(const Duration(days: 6));
    return _paid(
      BookingDto(
        id: 'bk-demo-past',
        ref: 'BEL-4T9K2M',
        state: 'confirmed',
        departureId: 'dep-demo-past',
        operatorName: 'Ocean du Nord',
        originCity: 'Pointe-Noire',
        destinationCity: 'Brazzaville',
        departsAt: departed,
        arrivesAt: departed.add(const Duration(hours: 7, minutes: 30)),
        passengers: const [
          PassengerDto(fullName: 'Aline Massamba', seatLabel: '7B'),
        ],
        fare: const Money.xaf(12000),
        serviceFee: const Money.xaf(300),
        total: const Money.xaf(12300),
        createdAt: departed.subtract(const Duration(days: 2)),
      ),
    );
  }

  @override
  Future<
    ({List<PaymentOptionDto> options, String? accountMsisdn, Money amount})
  >
  paymentOptions(String bookingId) async {
    await Future<void>.delayed(latency);
    final total = _booking?.total ?? const Money.xaf(12300);
    return (
      options: const [
        PaymentOptionDto(
          railId: 'cg.mtn_momo',
          operatorId: 'mtn',
          labelKey: 'enum.MobileOperator.mtn',
          collectionMsisdn: '242060000001',
          collectionName: 'Ocean du Nord',
          ussdCode: '*105#',
          recommended: true,
        ),
        PaymentOptionDto(
          railId: 'cg.airtel_money',
          operatorId: 'airtel',
          labelKey: 'enum.MobileOperator.airtel',
          collectionMsisdn: '242050000002',
          collectionName: 'Ocean du Nord',
          ussdCode: '*128#',
        ),
      ],
      accountMsisdn: '242061234567',
      amount: total,
    );
  }

  @override
  Future<PaymentIntentDto> startPayment({
    required String bookingId,
    required String railId,
    required String payerMsisdn,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(latency);
    _polls = 0;

    if (payerMsisdn
        .replaceAll(RegExp(r'[^0-9]'), '')
        .endsWith(decliningMsisdn)) {
      throw const ServerRefused(
        422,
        ApiError(code: 'payment.insufficient_funds'),
      );
    }

    return _intent = PaymentIntentDto(
      id: 'pi-demo-${++_counter}',
      state: 'pending',
      railId: railId,
      amount: _booking?.total ?? const Money.xaf(12300),
      createdAt: _now,
      expiresAt: _now.add(const Duration(minutes: 10)),
      pollAfterSeconds: 1,
    );
  }

  @override
  Future<PaymentIntentDto> paymentStatus(String intentId) async {
    await Future<void>.delayed(latency);

    // Two polls of waiting, so the waiting screen is actually seen. A demo
    // that settles instantly is a demo where nobody notices the spinner is
    // wrong.
    if (++_polls < 3) return _intent!;

    _booking = _paid(_booking!);
    return _intent = PaymentIntentDto(
      id: _intent!.id,
      state: 'captured',
      railId: _intent!.railId,
      amount: _intent!.amount,
      createdAt: _intent!.createdAt,
      bookingRef: _booking!.ref,
    );
  }

  static BookingDto _paid(BookingDto booking) => BookingDto(
    id: booking.id,
    ref: booking.ref,
    state: 'confirmed',
    departureId: booking.departureId,
    operatorName: booking.operatorName,
    originCity: booking.originCity,
    destinationCity: booking.destinationCity,
    departsAt: booking.departsAt,
    arrivesAt: booking.arrivesAt,
    passengers: booking.passengers,
    fare: booking.fare,
    serviceFee: booking.serviceFee,
    total: booking.total,
    createdAt: booking.createdAt,
    tickets: [
      for (final p in booking.passengers)
        TicketDto(
          id: 'tk-demo-${p.seatLabel}',
          bookingRef: booking.ref,
          seatLabel: p.seatLabel ?? '',
          passengerName: p.fullName,
          qrPayload: '1|BEL|${booking.ref}|${p.seatLabel}|demo',
          rotatingSecret: 'demo',
          keyId: 1,
          issuedAt: booking.createdAt,
        ),
    ],
  );

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
  // ── Sharing a trip ────────────────────────────────────────────────────────

  TripShareDto? _share;

  @override
  Future<TripShareDto> shareTrip(String bookingRef) async =>
      _share ??= TripShareDto(
        url: 'https://blt.cg/t/dEm0ShAr3T0k3n',
        expiresAt: DateTime.now().add(const Duration(hours: 14)),
        opens: 0,
        revoked: false,
      );

  @override
  Future<TripShareDto?> tripShare(String bookingRef) async => _share;

  @override
  Future<void> revokeTripShare(String bookingRef) async => _share = null;
}
