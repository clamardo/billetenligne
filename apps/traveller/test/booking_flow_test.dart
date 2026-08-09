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
final class _ScriptedGateway implements TravelGateway {
  _ScriptedGateway({this.searchResult});

  List<DepartureSummaryDto>? searchResult;
  ApiFailure? searchFailure;
  ApiFailure? holdFailure;

  final holdKeys = <String>[];
  final released = <String>[];
  var searches = 0;

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

void main() {
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

    test('expiry outside a hold is ignored', () async {
      final flow = BookingFlow(gateway: _ScriptedGateway(), isSignedIn: () => true);

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
