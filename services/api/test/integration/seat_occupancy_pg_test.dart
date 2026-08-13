@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// `seats.state` is nobody's to write (ADR-0025).
///
/// Every other suite asks what the state *says*. This one asks where it came
/// from, because the answer changed: a seat is taken by writing the piece of
/// road that is now occupied, and the state is a trigger's summary of those
/// rows. Two properties follow, and neither can be checked against a fake:
///
///   * **one row per sale, re-attributed rather than replaced.** A capture
///     that released the hold's occupancy and took new occupancy for the
///     booking would read identically afterwards, and would have left an
///     instant in which a paid seat was free;
///   * **no hold survives without its seats.** The claim path takes the seats
///     after writing the hold, so a claim that loses the race has to take the
///     hold down with it — otherwise the traveller's retry is answered with
///     "that key is spent" rather than with a seat.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresBookingStore bookings;
  late HoldSeats hold;
  late ReserveBooking reserve;
  late String userId;
  late String stationId;
  late String roadId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 12);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(11)),
    );
    hold = HoldSeats(inventory: PostgresSeatInventory(db));
    // No seeded random here, deliberately. The integration database is shared
    // by every suite in this directory, and two files reserving from the same
    // seed mint the same payment code — which the live-code unique index
    // refuses, correctly, in whichever suite happens to run second.
    reserve = ReserveBooking(bookings: bookings);
    userId = await fixture.traveller('910001', name: 'Aline M.');
    stationId = await fixture.station('BZV', 'Agence Occupancy');
    // A road of this suite's own, for the same reason: departures seeded here
    // would otherwise turn up in another suite's list of alternative coaches.
    roadId = await fixture.route(code: 'OCC', destination: 'OYO');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String key() => 'occ-${++seq}-${DateTime.now().microsecondsSinceEpoch}';

  group('a seat says what its occupancy says', () {
    test('a claim writes the whole road, and the state follows', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        onRoute: roadId,
      );
      final claimed = await hold(
        departureId: departureId,
        seatLabels: const ['1A'],
        userId: userId,
        idempotencyKey: key(),
      );

      final rows = await fixture.occupancyOn(departureId, '1A');
      expect(rows, hasLength(1));
      // The departure's own road, read inside the insert. Not a range built
      // in Dart, which could describe a journey nobody sold.
      expect(rows.single['span'], '[0,1)');
      expect(rows.single['hold_id'], claimed.valueOrNull!.id);
      expect(rows.single['booking_id'], isNull);

      // Nobody wrote this. The trigger did.
      expect(await fixture.seatStateOn(departureId, '1A'), 'held');
      expect(await fixture.seatStateOn(departureId, '1B'), 'available');
      expect(await fixture.occupancyOn(departureId, '1B'), isEmpty);
    });

    test('releasing the hold takes the row away, and the seat back', () async {
      final departureId = await fixture.departure(
        seatLabels: ['2A'],
        onRoute: roadId,
      );
      final claimed = await hold(
        departureId: departureId,
        seatLabels: const ['2A'],
        userId: userId,
        idempotencyKey: key(),
      );

      await PostgresSeatInventory(
        db,
      ).release(holdId: claimed.valueOrNull!.id, userId: userId);

      // Deleted, not marked. Occupancy is not a history — the hold is.
      expect(await fixture.occupancyOn(departureId, '2A'), isEmpty);
      expect(await fixture.seatStateOn(departureId, '2A'), 'available');
    });

    test('a reservation keeps the hold and moves its deadline', () async {
      final departureId = await fixture.departure(
        seatLabels: ['3A'],
        onRoute: roadId,
      );
      final claimed = await hold(
        departureId: departureId,
        seatLabels: const ['3A'],
        userId: userId,
        idempotencyKey: key(),
      );
      final holdId = claimed.valueOrNull!.id;
      final claimedUntil = claimed.valueOrNull!.expiresAt;

      await reserve(
        holdId: holdId,
        userId: userId,
        passengers: [const PassengerDto(fullName: 'Aline M.', seatLabel: '3A')],
      );

      // Still the hold's, and that is what makes an unpaid reservation read
      // as held rather than sold: it cannot board, and it cannot be resold.
      final rows = await fixture.occupancyOn(departureId, '3A');
      expect(rows, hasLength(1));
      expect(rows.single['hold_id'], holdId);
      expect(rows.single['booking_id'], isNull);
      expect(
        (rows.single['held_until'] as DateTime).isAfter(claimedUntil),
        isTrue,
        reason: 'the deadline moved out to the payment window',
      );
      expect(await fixture.seatStateOn(departureId, '3A'), 'held');
    });

    test(
      'payment re-attributes the row rather than taking a new one',
      () async {
        final departureId = await fixture.departure(
          seatLabels: ['4A'],
          onRoute: roadId,
        );
        final claimed = await hold(
          departureId: departureId,
          seatLabels: const ['4A'],
          userId: userId,
          idempotencyKey: key(),
        );
        final reserved = await reserve(
          holdId: claimed.valueOrNull!.id,
          userId: userId,
          passengers: [
            const PassengerDto(fullName: 'Aline M.', seatLabel: '4A'),
          ],
        );
        final booking = reserved.valueOrNull!;
        final before = await fixture.occupancyOn(departureId, '4A');

        await bookings.captureCash(
          bookingId: booking.id,
          operatorId: booking.operatorId,
          stationId: stationId,
          soldByUserId: null,
          posting: Postings.cashSale(
            operatorId: booking.operatorId,
            stationId: stationId,
            fare: booking.fare,
            serviceFee: booking.serviceFee,
          ).valueOrNull!,
        );

        final after = await fixture.occupancyOn(departureId, '4A');
        expect(after, hasLength(1));
        // The same row, changed hands. A release-and-retake would read the same
        // afterwards and would have left the seat free in between.
        expect(after.single['span'], before.single['span']);
        expect(after.single['booking_id'], booking.id);
        expect(after.single['hold_id'], isNull);
        expect(after.single['held_until'], isNull);
        expect(await fixture.seatStateOn(departureId, '4A'), 'sold');
      },
    );

    test('no hold outlives the seats it failed to take', () async {
      final departureId = await fixture.departure(
        seatLabels: ['5A'],
        onRoute: roadId,
      );
      final travellers = [
        for (var i = 0; i < 12; i++) await fixture.traveller('occ-race$i'),
      ];

      final results = await Future.wait([
        for (var i = 0; i < travellers.length; i++)
          hold(
            departureId: departureId,
            seatLabels: const ['5A'],
            userId: travellers[i],
            idempotencyKey: 'occ-race-$i-${DateTime.now().microsecond}',
          ),
      ]);

      expect(results.where((r) => r.isOk), hasLength(1));
      expect(await fixture.occupancyOn(departureId, '5A'), hasLength(1));
      // The whole claim is undone when the seats go elsewhere, so no loser
      // committed a hold — and no loser burned their idempotency key.
      expect(await fixture.emptyHolds(departureId), 0);
    });

    test('the derived state is not writable by an operator', () async {
      final departureId = await fixture.departure(
        seatLabels: ['6A'],
        onRoute: roadId,
      );

      // The grant is the control (migration 0036). A path added next year
      // that reaches for the state directly fails here rather than in
      // production, holding a seat nobody can account for.
      await expectLater(
        db.transaction(DbScope.tenant(PgFixture.operatorId), (tx) async {
          await tx.execute(
            "UPDATE seats SET state = 'blocked' "
            "WHERE departure_id = '$departureId'",
          );
        }),
        throwsA(isA<Exception>()),
      );

      expect(await fixture.seatStateOn(departureId, '6A'), 'available');
    });
  });
}
