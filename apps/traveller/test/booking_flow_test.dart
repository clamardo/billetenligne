import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_traveller/src/application/booking_flow.dart';
import 'package:bel_traveller/src/application/ports/travel_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// A gateway the test drives directly, and which records what it was asked.
///
/// The idempotency key is the interesting recording: whether a retry reuses it
/// is the difference between one hold and two.
/// Exported so `payment_flow_test` can drive the same fake.
///
/// One scripted gateway rather than two, for the reason the port itself gives:
/// search-seatmap-hold-reserve-pay is one conversation, and two fakes that
/// disagree about a booking make both suites meaningless.
typedef ScriptedGatewayFactory = _ScriptedGateway;

final class _ScriptedGateway implements TravelGateway {
  _ScriptedGateway({this.searchResult});

  List<DepartureSummaryDto>? searchResult;
  ApiFailure? citiesFailure;
  ApiFailure? searchFailure;
  ApiFailure? holdFailure;

  final holdKeys = <String>[];
  final released = <String>[];
  var searches = 0;

  @override
  Future<List<CityDto>> cities() async {
    if (citiesFailure != null) throw citiesFailure!;
    return const [
      CityDto(code: 'BZV', name: 'Brazzaville'),
      CityDto(code: 'PNR', name: 'Pointe-Noire'),
    ];
  }

  @override
  Future<List<DepartureSummaryDto>> search(SearchDeparturesQuery query) async {
    searches++;
    if (searchFailure != null) throw searchFailure!;
    return searchResult ?? const [];
  }

  @override
  Future<SeatMapDto> seatMap(String departureId) async => _seatMap(departureId);

  @override
  Future<HoldDto> hold({
    required String departureId,
    required List<String> seatLabels,
    required String idempotencyKey,
  }) async {
    holdKeys.add(idempotencyKey);
    if (holdFailure != null) throw holdFailure!;

    return HoldDto(
      id: 'hold-${holdKeys.length}',
      departureId: departureId,
      seatLabels: seatLabels,
      expiresAt: DateTime.utc(2026, 8, 9, 6, 15),
      fare: Money.xaf(12000 * seatLabels.length),
      serviceFee: const Money.xaf(300),
      total: Money.xaf(12000 * seatLabels.length + 300),
      state: 'active',
    );
  }

  ApiFailure? reserveFailure;
  BookingDto? reserveResult;
  final List<PassengerDto> reserved = [];
  final List<String> reserveKeys = [];

  @override
  Future<BookingDto> reserve({
    required String holdId,
    required List<PassengerDto> passengers,
    required String idempotencyKey,
  }) async {
    reserveKeys.add(idempotencyKey);
    if (reserveFailure != null) throw reserveFailure!;
    reserved
      ..clear()
      ..addAll(passengers);
    return reserveResult ??= _demoBooking(passengers);
  }

  // ── Paying ────────────────────────────────────────────────────────────────

  List<PaymentOptionDto> options = const [
    PaymentOptionDto(
      railId: 'cg.mtn_momo',
      operatorId: 'mtn',
      labelKey: 'enum.MobileOperator.mtn',
      collectionMsisdn: '242060000001',
      collectionName: 'Ocean du Nord',
      recommended: true,
    ),
    PaymentOptionDto(
      railId: 'cg.airtel_money',
      operatorId: 'airtel',
      labelKey: 'enum.MobileOperator.airtel',
      collectionMsisdn: '242050000002',
      collectionName: 'Ocean du Nord',
    ),
  ];

  String? accountMsisdn = '242061234567';
  ApiFailure? optionsFailure;
  ApiFailure? startPaymentFailure;

  final startedPayments = <({String railId, String payerMsisdn, String key})>[];
  final statusScript = <String>[];

  @override
  Future<BookingDto> booking(String bookingId) async =>
      reserveResult ??= _demoBooking(const []);

  /// What the tickets screen will find. Settable, because "one paid trip and
  /// one unpaid reservation" is the state worth testing and not one the
  /// funnel can reach on its own.
  List<BookingDto>? bookingsResult;
  ApiFailure? bookingsFailure;
  var bookingsCalls = 0;

  @override
  Future<List<BookingDto>> bookings() async {
    bookingsCalls++;
    if (bookingsFailure != null) throw bookingsFailure!;
    return bookingsResult ?? [reserveResult ??= _demoBooking(const [])];
  }

  // ── Cancelling ────────────────────────────────────────────────────────────

  /// What the server would answer. Settable, because "paid, 90% back, at a
  /// counter" is the state worth testing and not one the app can reach on
  /// its own.
  CancellationOfferDto? cancelOffer;
  CancellationDoneDto? cancelResult;

  /// Two failures, not one. The interesting path is a refused cancellation
  /// whose re-read succeeds — the sheet has to come back carrying what is now
  /// true — and a fake that fails both at once cannot express it.
  ApiFailure? cancelOfferFailure;
  ApiFailure? cancelFailure;
  final cancelCalls = <String>[];

  @override
  Future<CancellationOfferDto> cancellationOffer(String bookingRef) async {
    cancelCalls.add('offer:$bookingRef');
    if (cancelOfferFailure != null) throw cancelOfferFailure!;
    return cancelOffer ??= CancellationOfferDto(
      bookingRef: bookingRef,
      kind: 'release',
      departsAt: DateTime.utc(2026, 8, 11, 6),
      originCity: 'Brazzaville',
      destinationCity: 'Pointe-Noire',
      seatCount: 1,
      fare: Money(900000, Currency.xaf),
      serviceFee: Money(30000, Currency.xaf),
    );
  }

  @override
  Future<CancellationDoneDto> cancelBooking(String bookingRef) async {
    cancelCalls.add('cancel:$bookingRef');
    if (cancelFailure != null) throw cancelFailure!;
    return cancelResult ??= CancellationDoneDto(
      bookingRef: bookingRef,
      kind: 'release',
    );
  }

  // ── Sharing a trip ────────────────────────────────────────────────────────

  /// The link, as the server would answer. Settable, because "already shared,
  /// opened four times" is the state worth testing and not one the app can
  /// reach on its own.
  TripShareDto? shareResult;
  ApiFailure? shareFailure;
  final shareCalls = <String>[];

  @override
  Future<TripShareDto> shareTrip(String bookingRef) async {
    shareCalls.add('share:$bookingRef');
    if (shareFailure != null) throw shareFailure!;
    return shareResult ??= TripShareDto(
      url: 'https://blt.cg/t/scriptedtoken',
      expiresAt: DateTime.utc(2026, 8, 9, 20),
      opens: 0,
      revoked: false,
    );
  }

  @override
  Future<TripShareDto?> tripShare(String bookingRef) async {
    shareCalls.add('read:$bookingRef');
    if (shareFailure != null) throw shareFailure!;
    return shareResult;
  }

  @override
  Future<void> revokeTripShare(String bookingRef) async {
    shareCalls.add('revoke:$bookingRef');
    if (shareFailure != null) throw shareFailure!;
    shareResult = null;
  }

  // ── The passenger's own choice ────────────────────────────────────────────

  /// What the choice screen will find, and what the tap returns. Both
  /// settable: the interesting states here — a coach that filled, a window
  /// that closed — are ones no sequence of calls on this fake can reach.
  TravelChoicesDto? choicesResult;
  ChoiceAppliedDto? chooseResult;
  ApiFailure? choicesFailure;
  ApiFailure? chooseFailure;

  final choicesAsked = <String>[];
  final chosen = <String>[];

  @override
  Future<TravelChoicesDto> travelOptions(String bookingRef) async {
    choicesAsked.add(bookingRef);
    if (choicesFailure != null) throw choicesFailure!;
    return choicesResult ??
        TravelChoicesDto(
          bookingRef: bookingRef,
          options: const [],
          deadline: DateTime.utc(2026, 8, 9, 9),
          seatsNeeded: 1,
          originCity: 'Brazzaville',
          destinationCity: 'Pointe-Noire',
          open: true,
        );
  }

  @override
  Future<ChoiceAppliedDto> chooseTravel({
    required String bookingRef,
    required String optionId,
  }) async {
    chosen.add(optionId);
    if (chooseFailure != null) throw chooseFailure!;
    return chooseResult ??
        ChoiceAppliedDto(bookingRef: bookingRef, kind: 'keep');
  }

  @override
  Future<
    ({List<PaymentOptionDto> options, String? accountMsisdn, Money amount})
  >
  paymentOptions(String bookingId) async {
    if (optionsFailure != null) throw optionsFailure!;
    return (
      options: options,
      accountMsisdn: accountMsisdn,
      amount: const Money.xaf(12300),
    );
  }

  @override
  Future<PaymentIntentDto> startPayment({
    required String bookingId,
    required String railId,
    required String payerMsisdn,
    required String idempotencyKey,
  }) async {
    startedPayments.add((
      railId: railId,
      payerMsisdn: payerMsisdn,
      key: idempotencyKey,
    ));
    if (startPaymentFailure != null) throw startPaymentFailure!;
    return PaymentIntentDto(
      id: 'pi-1',
      state: 'pending',
      railId: railId,
      amount: const Money.xaf(12300),
      createdAt: DateTime.utc(2026, 8, 9, 6),
      pollAfterSeconds: 0,
    );
  }

  @override
  Future<PaymentIntentDto> paymentStatus(String intentId) async {
    final state = statusScript.isEmpty
        ? 'pending'
        : (statusScript.length == 1
              ? statusScript.first
              : statusScript.removeAt(0));
    return PaymentIntentDto(
      id: intentId,
      state: state,
      railId: 'cg.mtn_momo',
      amount: const Money.xaf(12300),
      createdAt: DateTime.utc(2026, 8, 9, 6),
      failureCode: state == 'failed' ? 'payment.wrong_pin' : null,
      pollAfterSeconds: 0,
    );
  }

  static BookingDto _demoBooking(List<PassengerDto> passengers) => BookingDto(
    id: 'bk-1',
    ref: 'BEL-7QK4M2',
    state: 'pending_payment',
    departureId: 'dep-1',
    operatorName: 'Ocean du Nord',
    originCity: 'BZV',
    destinationCity: 'PNR',
    departsAt: DateTime.utc(2026, 8, 10, 6),
    arrivesAt: DateTime.utc(2026, 8, 10, 14),
    passengers: passengers,
    fare: const Money.xaf(12000),
    serviceFee: const Money.xaf(300),
    total: const Money.xaf(12300),
    createdAt: DateTime.utc(2026, 8, 9),
    paymentCode: 'K4M2Q',
    paymentDeadline: DateTime.utc(2026, 8, 9, 10),
  );

  @override
  Future<void> release(String holdId) async => released.add(holdId);
}

DepartureSummaryDto _departure({String id = 'dep-1', int available = 40}) =>
    DepartureSummaryDto(
      id: id,
      operatorId: 'op-1',
      operatorName: 'Ocean du Nord',
      mode: 'bus',
      originCity: 'BZV',
      destinationCity: 'PNR',
      departsAt: DateTime.utc(2026, 8, 10, 5),
      arrivesAt: DateTime.utc(2026, 8, 10, 13),
      fare: const Money.xaf(12000),
      serviceFee: const Money.xaf(300),
      seatsAvailable: available,
      capacity: 52,
      seatSelectionEnabled: true,
    );

SeatMapDto _seatMap(String departureId) => SeatMapDto(
  departureId: departureId,
  mode: 'bus',
  layoutVersion: 1,
  sections: const [
    CabinSectionDto(
      code: 'STD',
      labelKey: 'seat.class.standard',
      rows: 3,
      abreast: '2+2',
    ),
  ],
  seats: [
    for (var row = 1; row <= 3; row++)
      for (final col in const ['A', 'B', 'C', 'D'])
        SeatDto(
          label: '$row$col',
          sectionCode: 'STD',
          status: SeatStatusDto.available,
          fare: const Money.xaf(12000),
        ),
  ],
);

final _query = SearchDeparturesQuery(
  originCity: 'BZV',
  destinationCity: 'PNR',
  date: DateTime.utc(2026, 8, 10),
);

/// Search, open the coach, pick 1A, hold it.
Future<void> _reachHold(BookingFlow flow, _ScriptedGateway gateway) async {
  await flow.start();
  await flow.search(_query);
  await flow.openSeatMap(_departure());
  flow.toggleSeat('1A');
  await flow.holdSelection();
}

void main() {
  group('launch', () {
    test('loads the cities the search screen needs', () async {
      final gateway = _ScriptedGateway();
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

      await flow.start();

      expect(flow.step, isA<Idle>());
      expect(flow.cities.map((c) => c.code), ['BZV', 'PNR']);
    });

    test('a failed city load is a failure, not an empty picker', () async {
      final gateway = _ScriptedGateway()
        ..citiesFailure = const NetworkUnreachable();
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

      await flow.start();

      // An empty picker reads as "we serve nowhere". Without cities there is
      // no query to type, so this is fatal to the funnel in a way a failed
      // search is not — and it is offered with a retry.
      expect(flow.step, isA<StepFailed>());
      expect((flow.step as StepFailed).recoverable, isTrue);
    });

    test('starting twice does not refetch', () async {
      final gateway = _ScriptedGateway();
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

      await flow.start();
      gateway.citiesFailure = const NetworkUnreachable();
      await flow.start();

      // The list changes a handful of times a year. Refetching on every
      // return to the search screen would spend a prepaid bundle on an answer
      // we already have.
      expect(flow.step, isA<Idle>());
    });

    test(
      'reset before the cities load does not strand on an empty picker',
      () async {
        final gateway = _ScriptedGateway()
          ..citiesFailure = const NetworkUnreachable();
        final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

        await flow.start();
        flow.reset();

        expect(flow.step, isA<Starting>());
      },
    );
  });

  group('search', () {
    test('produces results', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

      await flow.search(_query);

      expect(flow.step, isA<ResultsReady>());
      expect((flow.step as ResultsReady).departures, hasLength(1));
    });

    test(
      'a lost connection keeps the previous results, marked stale',
      () async {
        final gateway = _ScriptedGateway(searchResult: [_departure()]);
        final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

        await flow.search(_query);
        gateway.searchFailure = const NetworkUnreachable();
        await flow.search(_query);

        // Losing signal must not blank a screen somebody was reading. The 06:00
        // has not moved just because the radio dropped.
        final step = flow.step as ResultsReady;
        expect(step.stale, isTrue);
        expect(step.departures, hasLength(1));
      },
    );

    test('a first search with no signal fails honestly', () async {
      final gateway = _ScriptedGateway()
        ..searchFailure = const NetworkUnreachable();
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

      await flow.search(_query);

      // Nothing to fall back on. Pretending otherwise would be worse.
      expect(flow.step, isA<StepFailed>());
    });

    test('a refusal is never dressed up as stale results', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);

      await flow.search(_query);
      gateway.searchFailure = const ServerRefused(
        400,
        ApiError(code: ErrorCode.badRequest),
      );
      await flow.search(_query);

      // The server answered, and the answer was "your request is wrong".
      // Showing yesterday's coaches would hide a bug the traveller can fix.
      expect(flow.step, isA<StepFailed>());
    });
  });

  group('choosing seats', () {
    Future<BookingFlow> onSeatMap([_ScriptedGateway? g]) async {
      final gateway = g ?? _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await flow.search(_query);
      await flow.openSeatMap(_departure());
      return flow;
    }

    test('toggles on and off', () async {
      final flow = await onSeatMap();

      expect(flow.toggleSeat('1A'), isTrue);
      expect((flow.step as ChoosingSeats).selected, {'1A'});

      expect(flow.toggleSeat('1A'), isTrue);
      expect((flow.step as ChoosingSeats).selected, isEmpty);
    });

    test('refuses past the cap, and says so rather than going quiet', () async {
      final flow = await onSeatMap();

      for (final label in ['1A', '1B', '1C', '1D', '2A', '2B']) {
        expect(flow.toggleSeat(label), isTrue);
      }

      // A control that silently stops responding reads as a broken app.
      expect(flow.toggleSeat('2C'), isFalse);
      expect((flow.step as ChoosingSeats).selected, hasLength(6));
    });

    test('deselecting below the cap frees a slot again', () async {
      final flow = await onSeatMap();

      for (final label in ['1A', '1B', '1C', '1D', '2A', '2B']) {
        flow.toggleSeat(label);
      }
      flow.toggleSeat('1A');

      expect(flow.toggleSeat('2C'), isTrue);
    });

    test('prices the selection from the seat rows', () async {
      final flow = await onSeatMap();

      flow.toggleSeat('1A');
      flow.toggleSeat('1B');

      final step = flow.step as ChoosingSeats;
      expect(step.fare, const Money.xaf(24000));
      expect(step.total, const Money.xaf(24300));
    });
  });

  group('holding', () {
    Future<BookingFlow> ready(_ScriptedGateway gateway) async {
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await flow.search(_query);
      await flow.openSeatMap(_departure());
      flow.toggleSeat('1A');
      return flow;
    }

    test('holds the selection', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = await ready(gateway);

      await flow.holdSelection();

      expect(flow.step, isA<HoldReady>());
      expect((flow.step as HoldReady).hold.seatLabels, ['1A']);
    });

    test('an empty selection does nothing at all', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await flow.search(_query);
      await flow.openSeatMap(_departure());

      await flow.holdSelection();

      expect(flow.step, isA<ChoosingSeats>());
      expect(gateway.holdKeys, isEmpty);
    });

    test('a lost answer is retried with the SAME key', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()])
        ..holdFailure = const NetworkUnreachable();
      final flow = await ready(gateway);

      await flow.holdSelection();
      expect(flow.step, isA<StepFailed>());

      // The connection dropped; the server may well have created the hold.
      // Retrying with a fresh key would hold a second seat for somebody who
      // asked for one.
      gateway.holdFailure = null;
      await flow.backToSeatMap();
      flow.toggleSeat('1A');
      await flow.holdSelection();

      expect(gateway.holdKeys, hasLength(2));
      expect(gateway.holdKeys.toSet(), hasLength(1));
    });

    test(
      'a refusal ends the attempt, so the next try is genuinely new',
      () async {
        final gateway = _ScriptedGateway(searchResult: [_departure()])
          ..holdFailure = const ServerRefused(
            409,
            ApiError(code: ErrorCode.seatUnavailable),
          );
        final flow = await ready(gateway);

        await flow.holdSelection();

        gateway.holdFailure = null;
        await flow.backToSeatMap();
        flow.toggleSeat('2A');
        await flow.holdSelection();

        // The server already answered the first key. Reusing it would replay
        // that refusal forever.
        expect(gateway.holdKeys, hasLength(2));
        expect(gateway.holdKeys.toSet(), hasLength(2));
      },
    );

    test('a taken seat is not offered a retry button', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()])
        ..holdFailure = const ServerRefused(
          409,
          ApiError(code: ErrorCode.seatUnavailable),
        );
      final flow = await ready(gateway);

      await flow.holdSelection();

      // Trying again cannot produce a seat somebody else is sitting in.
      expect((flow.step as StepFailed).recoverable, isFalse);
    });

    test('a dropped connection IS offered a retry', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()])
        ..holdFailure = const NetworkUnreachable();
      final flow = await ready(gateway);

      await flow.holdSelection();

      expect((flow.step as StepFailed).recoverable, isTrue);
    });
  });

  group('releasing and expiry', () {
    test('releasing returns to the start', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await flow.search(_query);
      await flow.openSeatMap(_departure());
      flow.toggleSeat('1A');
      await flow.holdSelection();

      await flow.releaseHold();

      expect(gateway.released, hasLength(1));
      expect(flow.step, isA<Idle>());
    });

    test('a failed release still returns to the start', () async {
      final gateway = _FailingRelease();
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await flow.search(_query);
      await flow.openSeatMap(_departure());
      flow.toggleSeat('1A');
      await flow.holdSelection();

      await flow.releaseHold();

      // The hold expires by itself in minutes. Showing an error for an action
      // the traveller has already mentally completed costs more than the few
      // minutes of inventory.
      expect(flow.step, isA<Idle>());
    });

    test('expiry lands on a failure the screen can explain', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await flow.search(_query);
      await flow.openSeatMap(_departure());
      flow.toggleSeat('1A');
      await flow.holdSelection();

      flow.holdExpired();

      final step = flow.step as StepFailed;
      expect((step.failure as ServerRefused).code, ErrorCode.holdExpired);
      expect(step.recoverable, isFalse);
    });

    test('reserving turns a held seat into a payment code', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await _reachHold(flow, gateway);

      flow.namePassengers();
      expect(flow.step, isA<NamingPassengers>());

      await flow.reserve([
        const PassengerDto(fullName: 'Aline M.', seatLabel: '1A'),
      ]);

      final step = flow.step as Reserved;
      expect(step.booking.paymentCode, 'K4M2Q');
      expect(step.booking.state, 'pending_payment');
      // No ticket yet. The money has not moved, and a screen that looked
      // like a ticket before payment is the most confusing thing this flow
      // could do.
      expect(step.booking.tickets, isEmpty);
    });

    test('a refused reservation keeps the names on the form', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await _reachHold(flow, gateway);

      flow.namePassengers();
      gateway.reserveFailure = const NetworkUnreachable();
      await flow.reserve([
        const PassengerDto(fullName: 'Aline M.', seatLabel: '1A'),
      ]);

      // Back to the form rather than to an error screen: the names they
      // typed are still right, and most of these are fixed by trying again.
      final step = flow.step as NamingPassengers;
      expect(step.failure, isA<NetworkUnreachable>());
    });

    test('a retried reservation reuses the attempt key', () async {
      final gateway = _ScriptedGateway(searchResult: [_departure()]);
      final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
      await _reachHold(flow, gateway);
      flow.namePassengers();

      gateway.reserveFailure = const NetworkUnreachable();
      await flow.reserve([const PassengerDto(fullName: 'A', seatLabel: '1A')]);
      gateway.reserveFailure = null;
      await flow.reserve([const PassengerDto(fullName: 'A', seatLabel: '1A')]);

      // The same key both times. A second reservation would meet an
      // already-consumed hold and be refused, and the traveller would be told
      // nothing worked when in fact everything did.
      expect(gateway.reserveKeys, hasLength(2));
      expect(gateway.reserveKeys.first, gateway.reserveKeys.last);
    });

    test(
      'a refusal ends the attempt, so the next try is a new request',
      () async {
        final gateway = _ScriptedGateway(searchResult: [_departure()]);
        final flow = BookingFlow(gateway: gateway, isSignedIn: () => true);
        await _reachHold(flow, gateway);
        flow.namePassengers();

        gateway.reserveFailure = const ServerRefused(
          410,
          ApiError(code: ErrorCode.holdExpired),
        );
        await flow.reserve([
          const PassengerDto(fullName: 'A', seatLabel: '1A'),
        ]);
        gateway.reserveFailure = null;
        await flow.reserve([
          const PassengerDto(fullName: 'A', seatLabel: '1A'),
        ]);

        // The server answered. Reusing the key would ask it to replay an answer
        // it already gave.
        expect(gateway.reserveKeys.first, isNot(gateway.reserveKeys.last));
      },
    );

    test('expiry outside a hold is ignored', () async {
      final flow = BookingFlow(
        gateway: _ScriptedGateway(),
        isSignedIn: () => true,
      );

      flow.holdExpired();

      // A timer that fires after the traveller has already moved on must not
      // throw them into an error screen.
      expect(flow.step, isA<Idle>());
    });
  });
}

final class _FailingRelease extends _ScriptedGateway {
  _FailingRelease() : super(searchResult: [_departure()]);

  @override
  Future<void> release(String holdId) async => throw const NetworkUnreachable();
}
