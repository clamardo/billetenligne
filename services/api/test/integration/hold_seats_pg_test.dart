@Tags(['integration'])
library;

import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The seat race, against the lock manager that will actually arbitrate it.
///
/// Everything the in-memory suite proves is proven there in milliseconds. This
/// file exists for the one claim a fake cannot make: **that fifty travellers
/// reaching for seat 1A at 06:00 produce exactly one ticket.** There is no
/// concurrency to lose to in a Dart map, so a fake asserting this would be
/// asserting nothing at all.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    // Skipped, not failed. A red suite that means "you did not start Docker"
    // teaches people to ignore red suites.
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresSeatInventory inventory;
  late HoldSeats holdSeats;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 12);
    inventory = PostgresSeatInventory(db);
    holdSeats = HoldSeats(inventory: inventory);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  group('one seat, one winner', () {
    test('fifty concurrent travellers produce exactly one hold', () async {
      final departureId = await fixture.departure(seatLabels: ['1A']);
      final travellers = [
        for (var i = 0; i < 50; i++) await fixture.traveller('race$i'),
      ];

      // Fired together, deliberately without awaiting between them. This is
      // the 06:00 Brazzaville–Pointe-Noire departure with one seat left and a
      // WhatsApp group that has just been told about it.
      final results = await Future.wait([
        for (var i = 0; i < travellers.length; i++)
          holdSeats(
            departureId: departureId,
            seatLabels: const ['1A'],
            userId: travellers[i],
            idempotencyKey: 'race-key-$i',
          ),
      ]);

      final winners = results.where((r) => r.isOk).toList();
      expect(winners, hasLength(1), reason: 'exactly one traveller may win');

      // And everyone else was told the truth: the seat is taken, not that
      // something went wrong.
      final losers = results.where((r) => r.isErr);
      expect(losers, hasLength(49));
      for (final loser in losers) {
        expect(loser.failureOrNull, isA<SeatsAlreadyTaken>());
      }

      // The rows agree with the answers. A handler that reports success while
      // the database says otherwise is the failure mode worth checking for.
      expect(await fixture.seatStates(departureId), {'1A': 'held'});
      expect(await fixture.countHolds(departureId), 1);
    });

    test('a full coach sells every seat exactly once', () async {
      final labels = [
        for (var row = 1; row <= 5; row++)
          for (final col in const ['A', 'B', 'C', 'D']) '$row$col',
      ];
      final departureId = await fixture.departure(seatLabels: labels);

      // Twenty seats, sixty travellers, each asking for a random-ish pair.
      // Overlapping requests are the point: the pairs collide constantly.
      final travellers = [
        for (var i = 0; i < 60; i++) await fixture.traveller('coach$i'),
      ];

      final results = await Future.wait([
        for (var i = 0; i < travellers.length; i++)
          holdSeats(
            departureId: departureId,
            // Deliberately reversed for odd i, so half the requests arrive in
            // the opposite lock order. Unsorted, this is a deadlock.
            seatLabels: i.isEven
                ? [labels[i % labels.length], labels[(i + 1) % labels.length]]
                : [labels[(i + 1) % labels.length], labels[i % labels.length]],
            userId: travellers[i],
            idempotencyKey: 'coach-key-$i',
          ),
      ]);

      final held = <String>[];
      for (final result in results) {
        final dto = result.valueOrNull;
        if (dto != null) held.addAll(dto.seatLabels);
      }

      // No seat appears on two holds. This is the invariant the whole product
      // rests on: two people at a coach door with valid tickets for one seat
      // is not a bug anyone can apologise their way out of at 05:00.
      expect(held.toSet(), hasLength(held.length));

      final states = await fixture.seatStates(departureId);
      expect(
        states.entries
            .where((e) => e.value == 'held')
            .map((e) => e.key)
            .toSet(),
        held.toSet(),
      );
    });
  });

  group('idempotency, against the unique index', () {
    test('a retry returns the same hold rather than a second one', () async {
      final departureId = await fixture.departure(seatLabels: ['2A', '2B']);
      final userId = await fixture.traveller('retry1');

      final first = await holdSeats(
        departureId: departureId,
        seatLabels: const ['2A'],
        userId: userId,
        idempotencyKey: 'retry-key',
      );
      final retry = await holdSeats(
        departureId: departureId,
        seatLabels: const ['2A'],
        userId: userId,
        idempotencyKey: 'retry-key',
      );

      expect(retry.isOk, isTrue);
      expect(retry.valueOrNull!.id, first.valueOrNull!.id);
      expect(await fixture.countHolds(departureId), 1);
    });

    test('concurrent retries of one key still produce one hold', () async {
      final departureId = await fixture.departure(seatLabels: ['3A']);
      final userId = await fixture.traveller('retry2');

      // The app fired, the connection stalled, the user tapped again, and both
      // requests are now in flight. The unique index is what settles it.
      final results = await Future.wait([
        for (var i = 0; i < 8; i++)
          holdSeats(
            departureId: departureId,
            seatLabels: const ['3A'],
            userId: userId,
            idempotencyKey: 'concurrent-retry',
          ),
      ]);

      final ids = results
          .map((r) => r.valueOrNull?.id)
          .whereType<String>()
          .toSet();
      expect(ids, hasLength(1));
      expect(await fixture.countHolds(departureId), 1);
    });

    test("another traveller's key is refused as a key problem", () async {
      final departureId = await fixture.departure(seatLabels: ['4A', '4B']);
      final aline = await fixture.traveller('shared1');
      final serge = await fixture.traveller('shared2');

      await holdSeats(
        departureId: departureId,
        seatLabels: const ['4A'],
        userId: aline,
        idempotencyKey: 'shared-key',
      );

      final other = await holdSeats(
        departureId: departureId,
        seatLabels: const ['4B'],
        userId: serge,
        idempotencyKey: 'shared-key',
      );

      // 4B was free. Reporting "seat unavailable" would send an honest client
      // hunting for a seat that was never the problem.
      expect(other.failureOrNull, isA<HoldKeyBelongsToAnother>());
    });
  });

  group('expiry is the database\'s decision', () {
    test('a lapsed hold releases the seat with no sweeper running', () async {
      final departureId = await fixture.departure(seatLabels: ['5A']);
      final aline = await fixture.traveller('lapse1');
      final serge = await fixture.traveller('lapse2');

      final first = await holdSeats(
        departureId: departureId,
        seatLabels: const ['5A'],
        userId: aline,
        idempotencyKey: 'lapse-1',
      );

      // No worker runs between these two lines. A sweeper that has been stuck
      // for ten minutes must not be able to strand an operator's inventory.
      await fixture.expireHold(first.valueOrNull!.id);

      final second = await holdSeats(
        departureId: departureId,
        seatLabels: const ['5A'],
        userId: serge,
        idempotencyKey: 'lapse-2',
      );

      expect(second.isOk, isTrue);
    });

    test('the expiry comes from Postgres, not from this process', () async {
      final departureId = await fixture.departure(seatLabels: ['6A']);
      final userId = await fixture.traveller('clock1');

      final before = DateTime.now().toUtc();
      final hold = await holdSeats(
        departureId: departureId,
        seatLabels: const ['6A'],
        userId: userId,
        idempotencyKey: 'clock-key',
      );

      final expiresAt = hold.valueOrNull!.expiresAt;
      final ttl = HoldPolicy.standard.ttl;

      // Within a few seconds of this machine's clock, but computed by the
      // database — which is what keeps three API instances with three slightly
      // different clocks agreeing about who owns seat 6A.
      expect(
        expiresAt.difference(before.add(ttl)).abs(),
        lessThan(const Duration(seconds: 30)),
      );
    });
  });

  group('a departure that cannot be sold', () {
    test('cancelled is refused with its own code', () async {
      final departureId = await fixture.departure(
        seatLabels: ['7A'],
        status: 'cancelled',
      );
      final userId = await fixture.traveller('cancel1');

      final result = await holdSeats(
        departureId: departureId,
        seatLabels: const ['7A'],
        userId: userId,
        idempotencyKey: 'cancel-key',
      );

      expect(result.failureOrNull!.code, 'departure.cancelled');
      expect(await fixture.seatStates(departureId), {'7A': 'available'});
    });

    test('closed sales are refused even before departure', () async {
      final departureId = await fixture.departure(
        seatLabels: ['8A'],
        fromNow: const Duration(hours: 2),
        salesCloseIn: const Duration(seconds: -1),
      );
      final userId = await fixture.traveller('closed1');

      final result = await holdSeats(
        departureId: departureId,
        seatLabels: const ['8A'],
        userId: userId,
        idempotencyKey: 'closed-key',
      );

      // The coach has not left, but the manifest has been printed. A
      // passenger the conductor has no record of is worse than a lost sale.
      expect(result.failureOrNull!.code, 'departure.closed');
    });

    test('a departure that has already left is refused', () async {
      final departureId = await fixture.departure(
        seatLabels: ['9A'],
        fromNow: const Duration(hours: -1),
      );
      final userId = await fixture.traveller('gone1');

      final result = await holdSeats(
        departureId: departureId,
        seatLabels: const ['9A'],
        userId: userId,
        idempotencyKey: 'gone-key',
      );

      expect(result.failureOrNull!.code, 'departure.closed');
    });

    test('an unknown departure is a 404, not a crash', () async {
      final userId = await fixture.traveller('missing1');

      final result = await holdSeats(
        departureId: '00000000-0000-0000-0000-0000000000ff',
        seatLabels: const ['1A'],
        userId: userId,
        idempotencyKey: 'missing-key',
      );

      expect(result.failureOrNull!.code, 'resource.not_found');
    });
  });

  group('the public role cannot exceed its brief', () {
    test('a sold seat reads as taken, not as missing', () async {
      final departureId = await fixture.departure(seatLabels: ['10A']);
      final userId = await fixture.traveller('sold1');

      // Sold by the system after payment — a state the traveller's own role
      // has no way of writing.
      await db.transaction(DbScope.tenant(PgFixture.operatorId), (tx) async {
        await tx.execute(
          "UPDATE seats SET state = 'blocked', hold_id = NULL "
          "WHERE departure_id = '$departureId' AND seat_label = '10A'",
        );
      });

      final result = await holdSeats(
        departureId: departureId,
        seatLabels: const ['10A'],
        userId: userId,
        idempotencyKey: 'sold-key',
      );

      // The distinction matters: "not on this coach" tells the traveller their
      // seat map is stale and to reload. "Taken" tells them the truth, which
      // is that they were a second too slow.
      expect(result.failureOrNull, isA<SeatsAlreadyTaken>());
    });

    test('releasing is scoped to the owner', () async {
      final departureId = await fixture.departure(seatLabels: ['11A']);
      final aline = await fixture.traveller('release1');
      final serge = await fixture.traveller('release2');

      final hold = await holdSeats(
        departureId: departureId,
        seatLabels: const ['11A'],
        userId: aline,
        idempotencyKey: 'release-key',
      );
      final holdId = hold.valueOrNull!.id;

      // A leaked hold id is not a way to free somebody else's seat.
      expect(await inventory.release(holdId: holdId, userId: serge), isFalse);
      expect(await fixture.seatStates(departureId), {'11A': 'held'});

      expect(await inventory.release(holdId: holdId, userId: aline), isTrue);
      expect(await fixture.seatStates(departureId), {'11A': 'available'});
    });

    test('seats not on the departure are named, not swallowed', () async {
      final departureId = await fixture.departure(seatLabels: ['12A']);
      final userId = await fixture.traveller('unknown1');

      final result = await holdSeats(
        departureId: departureId,
        seatLabels: const ['99Z'],
        userId: userId,
        idempotencyKey: 'unknown-key',
      );

      expect(result.failureOrNull, isA<SeatsNotOnDeparture>());
    });
  });
}
