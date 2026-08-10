import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 10, 6);

  PartyToMove party(String id, int seats, int minute) => PartyToMove(
    bookingId: id,
    seats: seats,
    bookedAt: t0.subtract(Duration(days: 3, minutes: -minute)),
  );

  group('which departure can stand in for another', () {
    RebookingRefusal? refuse({
      String replacementId = 'dep-2',
      String replacementRouteId = 'r-1',
      String replacementStatus = 'scheduled',
      Duration later = const Duration(hours: 8),
    }) => refuseReplacement(
      departureId: 'dep-1',
      replacementId: replacementId,
      routeId: 'r-1',
      replacementRouteId: replacementRouteId,
      replacementStatus: replacementStatus,
      departsAt: t0,
      replacementDepartsAt: t0.add(later),
      now: t0.subtract(const Duration(hours: 1)),
    );

    test('a later departure on the same road is usable', () {
      expect(refuse(), isNull);
    });

    test('the departure cannot rescue itself', () {
      expect(refuse(replacementId: 'dep-1'), isA<SameDeparture>());
    });

    test('another road is a different journey, not a re-accommodation', () {
      // BZV–PNR onto BZV–Oyo is not "the next departure", whatever the
      // seat count says.
      expect(refuse(replacementRouteId: 'r-2'), isA<DifferentRoute>());
    });

    test('a replacement that leaves earlier cannot be reached', () {
      expect(
        refuse(later: const Duration(hours: -2)),
        isA<ReplacementNotLater>(),
      );
    });

    test('a cancelled replacement is not a re-accommodation', () {
      expect(
        refuse(replacementStatus: 'cancelled'),
        isA<ReplacementNotSellable>(),
      );
    });

    test('a replacement running late is still a replacement', () {
      // A coach an hour behind is still a coach. Refusing it because it has
      // its own problem leaves the passenger with none at all.
      expect(refuse(replacementStatus: 'delayed'), isNull);
    });

    test('a replacement that has already gone is refused', () {
      expect(
        refuseReplacement(
          departureId: 'dep-1',
          replacementId: 'dep-2',
          routeId: 'r-1',
          replacementRouteId: 'r-1',
          replacementStatus: 'scheduled',
          departsAt: t0.subtract(const Duration(hours: 4)),
          replacementDepartsAt: t0.subtract(const Duration(hours: 1)),
          now: t0,
        ),
        isA<ReplacementHasLeft>(),
      );
    });
  });

  group('who gets the seats', () {
    test('everybody fits when there is room', () {
      final plan = allocateRebooking(
        parties: [party('b-1', 2, 0), party('b-2', 1, 5)],
        seatsAvailable: 18,
      );

      expect(plan.coversEverybody, isTrue);
      expect(plan.passengersMoved, 3);
      expect(plan.passengersLeft, 0);
    });

    test('whoever booked first is moved first', () {
      // The only ordering a dispatcher can say out loud to somebody who was
      // left behind. Note b-2 was booked before b-1.
      final plan = allocateRebooking(
        parties: [party('b-1', 2, 40), party('b-2', 2, 5)],
        seatsAvailable: 2,
      );

      expect(plan.moved.single.bookingId, 'b-2');
      expect(plan.left.single.bookingId, 'b-1');
    });

    test('a party moves whole or not at all', () {
      // Splitting a family across two departures to make the arithmetic come
      // out is not a solution anybody would accept at a counter.
      final plan = allocateRebooking(
        parties: [party('b-1', 4, 0)],
        seatsAvailable: 3,
      );

      expect(plan.moved, isEmpty);
      expect(plan.passengersLeft, 4);
    });

    test('a family that does not fit does not strand the queue behind it', () {
      // Four seats free. The family of four booked first but arrives after a
      // pair has taken two — skipping them and filling the rest covers three
      // people instead of one.
      final plan = allocateRebooking(
        parties: [
          party('family', 3, 0),
          party('pair', 2, 10),
          party('solo', 1, 20),
        ],
        seatsAvailable: 3,
      );

      expect(plan.moved.map((p) => p.bookingId), ['family']);
      expect(plan.passengersMoved, 3);

      final tighter = allocateRebooking(
        parties: [
          party('family', 3, 0),
          party('pair', 2, 10),
          party('solo', 1, 20),
        ],
        seatsAvailable: 2,
      );

      // The family cannot go, and the two behind them still can.
      expect(tighter.moved.map((p) => p.bookingId), ['pair']);
      expect(tighter.left.map((p) => p.bookingId), ['family', 'solo']);
    });

    test('partial coverage is reported as a number, not as a failure', () {
      final plan = allocateRebooking(
        parties: [for (var i = 0; i < 42; i++) party('b-$i', 1, i)],
        seatsAvailable: 18,
      );

      // "18 / 42" is the honest answer, and the one a dispatcher combines
      // with a rescue coach to cover everybody.
      expect(plan.passengersMoved, 18);
      expect(plan.passengersLeft, 24);
      expect(plan.passengersTotal, 42);
      expect(plan.coversEverybody, isFalse);
    });

    test('a full replacement moves nobody', () {
      final plan = allocateRebooking(
        parties: [party('b-1', 1, 0)],
        seatsAvailable: 0,
      );

      expect(plan.moved, isEmpty);
      expect(plan.coversEverybody, isFalse);
    });
  });
}
