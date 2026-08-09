import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/infrastructure/memory/memory_seat_inventory.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// The rules that hold regardless of which database is underneath.
///
/// Everything here runs in milliseconds against the in-memory inventory. What
/// it deliberately does **not** cover is the seat race — fifty concurrent
/// claims cannot be proven correct where there is no concurrency to lose to.
/// That proof is in `integration/hold_seats_pg_test.dart` and needs a real
/// Postgres to mean anything.
void main() {
  final now = DateTime.utc(2026, 8, 9, 6);
  final clock = FixedClock(now);

  MemorySeatInventory freshInventory() => MemorySeatInventory(
    clock: clock,
    departures: [
      MemoryDeparture.coach(
        id: 'dep-1',
        operatorId: 'op-1',
        departsAt: now.add(const Duration(hours: 6)),
      ),
      MemoryDeparture.coach(
        id: 'dep-cancelled',
        operatorId: 'op-1',
        departsAt: now.add(const Duration(hours: 6)),
        status: 'cancelled',
      ),
      MemoryDeparture.coach(
        id: 'dep-gone',
        operatorId: 'op-1',
        departsAt: now.subtract(const Duration(minutes: 5)),
      ),
    ],
  );

  group('claiming', () {
    test('holds the requested seats and prices them from the rows', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-1',
        seatLabels: ['3B', '3A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      final dto = result.valueOrNull!;
      // Sorted on the way in. Two travellers asking for the same pair in
      // opposite orders must lock the rows in the same sequence.
      expect(dto.seatLabels, ['3A', '3B']);
      expect(dto.fare, const Money.xaf(24000));
      expect(dto.serviceFee, Market.current.serviceFee);
      expect(dto.total, const Money.xaf(24000) + Market.current.serviceFee);
      expect(dto.expiresAt, now.add(HoldPolicy.standard.ttl));
    });

    test(
      'charges the service fee once per booking, not once per seat',
      () async {
        final hold = HoldSeats(inventory: freshInventory());

        final one = await hold(
          departureId: 'dep-1',
          seatLabels: ['1A'],
          userId: 'u-aline',
          idempotencyKey: 'k1',
        );
        final four = await hold(
          departureId: 'dep-1',
          seatLabels: ['2A', '2B', '2C', '2D'],
          userId: 'u-serge',
          idempotencyKey: 'k2',
        );

        // A family of four is one transaction on one wallet. Four fees would be
        // indefensible when the receipt is read aloud at the counter.
        expect(four.valueOrNull!.serviceFee, one.valueOrNull!.serviceFee);
      },
    );

    test('normalises case and whitespace', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-1',
        seatLabels: [' 4a '],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(result.valueOrNull!.seatLabels, ['4A']);
    });
  });

  group('refusals', () {
    test('names exactly the seats that were taken', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      await hold(
        departureId: 'dep-1',
        seatLabels: ['5A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      final second = await hold(
        departureId: 'dep-1',
        seatLabels: ['5A', '5B'],
        userId: 'u-serge',
        idempotencyKey: 'k2',
      );

      final failure = second.failureOrNull! as SeatsAlreadyTaken;
      // 5B was free. Greying the whole request would tell the traveller to
      // give up on a seat they could still have.
      expect(failure.seatLabels, ['5A']);
    });

    test('a lapsed hold is available again without a sweeper', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      await hold(
        departureId: 'dep-1',
        seatLabels: ['6A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      // Fifteen minutes and one second later. Nothing has run in between —
      // no worker, no cron. A stalled sweeper must not be able to strand an
      // operator's inventory.
      final later = HoldSeats(
        inventory: MemorySeatInventory(
          clock: FixedClock(now.add(const Duration(minutes: 16))),
          departures: [inventory.departure('dep-1')!],
        ),
      );

      final second = await later(
        departureId: 'dep-1',
        seatLabels: ['6A'],
        userId: 'u-serge',
        idempotencyKey: 'k2',
      );

      expect(second.isOk, isTrue);
    });

    test('refuses a cancelled departure with its own code', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-cancelled',
        seatLabels: ['1A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(result.failureOrNull!.code, 'departure.cancelled');
    });

    test('refuses a departure that has already left', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-gone',
        seatLabels: ['1A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(result.failureOrNull!.code, 'departure.closed');
    });

    test('names seats that are not on this coach', () async {
      final hold = HoldSeats(inventory: freshInventory());

      // The operator swapped a 70-seat coach for a 51-seat one after a
      // breakdown and the app is holding a stale seat map.
      final result = await hold(
        departureId: 'dep-1',
        seatLabels: ['99Z'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(result.failureOrNull, isA<SeatsNotOnDeparture>());
    });

    test('rejects an empty request', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-1',
        seatLabels: [],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(result.failureOrNull, isA<NoSeatsRequested>());
    });

    test('caps a hold at six seats', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-1',
        seatLabels: ['1A', '1B', '1C', '1D', '2A', '2B', '2C'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      // Not a technical limit. Holding twenty seats on a fifty-seat coach with
      // no intention of paying is the cheapest denial of service there is.
      expect(result.failureOrNull, isA<TooManySeats>());
    });

    test('rejects the same seat twice in one request', () async {
      final hold = HoldSeats(inventory: freshInventory());

      final result = await hold(
        departureId: 'dep-1',
        seatLabels: ['1A', '1a'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      // Otherwise the traveller is quietly charged twice for one seat.
      expect(result.failureOrNull, isA<DuplicateSeatRequested>());
    });
  });

  group('idempotency', () {
    test('a retry returns the same hold, not a second one', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      final first = await hold(
        departureId: 'dep-1',
        seatLabels: ['7A'],
        userId: 'u-aline',
        idempotencyKey: 'same-key',
      );
      final retry = await hold(
        departureId: 'dep-1',
        seatLabels: ['7A'],
        userId: 'u-aline',
        idempotencyKey: 'same-key',
      );

      // The traveller's connection dropped and the app retried. They must see
      // the hold they already have, not "seat unavailable" naming the seat
      // they themselves are holding.
      expect(retry.isOk, isTrue);
      expect(retry.valueOrNull!.id, first.valueOrNull!.id);
    });

    test('another traveller cannot reuse the key', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      await hold(
        departureId: 'dep-1',
        seatLabels: ['8A'],
        userId: 'u-aline',
        idempotencyKey: 'shared',
      );

      final other = await hold(
        departureId: 'dep-1',
        seatLabels: ['8B'],
        userId: 'u-serge',
        idempotencyKey: 'shared',
      );

      // Reported as what it is. Saying "seat unavailable" would send an honest
      // client hunting for a seat that was never the problem.
      expect(other.failureOrNull, isA<HoldKeyBelongsToAnother>());
    });
  });

  group('releasing', () {
    test('puts the seats back', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      final first = await hold(
        departureId: 'dep-1',
        seatLabels: ['9A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(
        await inventory.release(
          holdId: first.valueOrNull!.id,
          userId: 'u-aline',
        ),
        isTrue,
      );

      final second = await hold(
        departureId: 'dep-1',
        seatLabels: ['9A'],
        userId: 'u-serge',
        idempotencyKey: 'k2',
      );
      expect(second.isOk, isTrue);
    });

    test('a leaked hold id does not let a stranger release it', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      final first = await hold(
        departureId: 'dep-1',
        seatLabels: ['10A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );

      expect(
        await inventory.release(
          holdId: first.valueOrNull!.id,
          userId: 'u-serge',
        ),
        isFalse,
      );
    });

    test('releasing twice is a no-op, not an error', () async {
      final inventory = freshInventory();
      final hold = HoldSeats(inventory: inventory);

      final first = await hold(
        departureId: 'dep-1',
        seatLabels: ['11A'],
        userId: 'u-aline',
        idempotencyKey: 'k1',
      );
      final id = first.valueOrNull!.id;

      expect(await inventory.release(holdId: id, userId: 'u-aline'), isTrue);
      // The second tap of a "Cancel" button is not a failure.
      expect(await inventory.release(holdId: id, userId: 'u-aline'), isFalse);
    });
  });
}
