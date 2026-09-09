@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/departure_catalogue.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_departure_catalogue.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_trip_sharing.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// J13 — a suspended company stops selling and keeps its promises.
///
/// `03-operator-lifecycle.md` §1 states the rule:
///
/// > `suspended` and `offboarding` both stop new sales but honour issued
/// > tickets. A platform that strands paying passengers to punish an operator
/// > has punished the wrong party.
///
/// `verify_public.sql` proves it at the schema, where it belongs — no
/// implementation that simply hides the operator's rows can satisfy both
/// halves. This file proves the adapters above it agree: search goes empty, a
/// new hold is refused, and the passenger who already paid still has a coach,
/// a ticket and a manifest with their name on it.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresDepartureCatalogue catalogue;
  late PostgresSeatInventory inventory;
  late PostgresBookingStore bookings;
  late PostgresOperatorConsole console;
  late PostgresTripSharing sharing;
  late String stationId;
  late String staffId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 6);
    catalogue = PostgresDepartureCatalogue(
      db,
      timeZone: Market.current.timeZone,
    );
    inventory = PostgresSeatInventory(db);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(131)),
    );
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    sharing = PostgresTripSharing(db, random: Random(137));
    stationId = await fixture.station('BZV', 'Agence suspension');
    staffId = await fixture.traveller('suspend-actor', name: 'Guichetier');
  });

  // Every file in this suite shares one database and one company. A test that
  // left it suspended would be the next file's inexplicable empty search.
  tearDown(() => fixture.setOperatorStatus(PgFixture.operatorId, 'active'));

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A coach three days out, and a paid seat on it.
  Future<({String depId, String ref, String bookingId, String userId})>
  soldSeat() async {
    final departureId = await fixture.departure(
      seatLabels: const ['1A', '1B'],
      fromNow: const Duration(days: 3),
      fareMinor: 9000,
    );
    final booking = await fixture.reserve(
      db: db,
      bookings: bookings,
      departureId: departureId,
      seatLabel: '1A',
      name: 'Aline M.',
    );
    await bookings.captureCash(
      bookingId: booking.id,
      operatorId: PgFixture.operatorId,
      stationId: stationId,
      soldByUserId: staffId,
      posting: Postings.cashSale(
        operatorId: PgFixture.operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );
    return (
      depId: departureId,
      ref: booking.ref.value,
      bookingId: booking.id,
      userId: await fixture.purchaserOf(booking.id),
    );
  }

  Future<List<String>> searchIds() async => [
    for (final row in await catalogue.search(
      DepartureQuery(
        originCity: 'BZV',
        destinationCity: 'PNR',
        localDate: await fixture.localDateIn(const Duration(days: 3)),
      ),
    ))
      row.id,
  ];

  group('the sales stop', () {
    test('a suspended company disappears from search', () async {
      final trip = await soldSeat();
      expect(await searchIds(), contains(trip.depId));

      await fixture.setOperatorStatus(PgFixture.operatorId, 'suspended');

      expect(await searchIds(), isNot(contains(trip.depId)));
    });

    test('offboarding stops the sales too', () async {
      final trip = await soldSeat();
      await fixture.setOperatorStatus(PgFixture.operatorId, 'offboarding');

      // §1 names both states and means both. A company winding down is not a
      // company still taking money for coaches it may not run.
      expect(await searchIds(), isNot(contains(trip.depId)));
    });

    test('a new hold on that coach is refused', () async {
      final trip = await soldSeat();
      await fixture.setOperatorStatus(PgFixture.operatorId, 'suspended');

      final held = await HoldSeats(inventory: inventory)(
        departureId: trip.depId,
        seatLabels: const ['1B'],
        userId: await fixture.traveller('suspend-latecomer'),
        idempotencyKey: 'suspend-${DateTime.now().microsecondsSinceEpoch}',
      );

      // Not merely absent from a search row: a traveller holding a deep link
      // to this departure cannot start a purchase either. The whole point of
      // moving the rule into the policy is that stopping the sale does not
      // rest on one query remembering to join `operators`.
      expect(held.isOk, isFalse);
    });

    test('reinstating puts the coach back on sale', () async {
      final trip = await soldSeat();
      await fixture.setOperatorStatus(PgFixture.operatorId, 'suspended');
      expect(await searchIds(), isNot(contains(trip.depId)));

      await fixture.setOperatorStatus(PgFixture.operatorId, 'active');

      expect(await searchIds(), contains(trip.depId));
    });
  });

  group('the promises are kept', () {
    test('the passenger still has a coach to look at', () async {
      final trip = await soldSeat();
      await fixture.setOperatorStatus(PgFixture.operatorId, 'suspended');

      // Read under the traveller's own scope. The arm of the 0051-era policy
      // that survives suspension is the one keyed on their booking, which is
      // the whole of "honour issued tickets" at the row level.
      final journey = await sharing.journey(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: DateTime.now().toUtc(),
      );

      expect(journey, isNotNull);
      expect(journey!.status, 'scheduled');
    });

    test('the ticket is still on the manifest, and not void', () async {
      final trip = await soldSeat();
      await fixture.setOperatorStatus(PgFixture.operatorId, 'suspended');

      // Boarding reads under the operator's OWN tenant scope, never the
      // public one, which is why suspension cannot reach the door. A rule on
      // `tickets` written to stop the sales would fail here.
      final manifest = await console.manifest(
        operatorId: PgFixture.operatorId,
        departureId: trip.depId,
      );

      expect(manifest, isNotNull);
      expect(manifest!.rows.map((r) => r.seatLabel), contains('1A'));
      expect(await fixture.ticketSeats(trip.bookingId), ['1A']);
    });

    test('and none of it needed the company to be readable', () async {
      final trip = await soldSeat();
      await fixture.setOperatorStatus(PgFixture.operatorId, 'suspended');

      // The company itself is gone from the public surface — that is what
      // `operators_public_read` has always said. The passenger's coach is
      // still there anyway, which is the half a naive implementation loses.
      expect(await searchIds(), isNot(contains(trip.depId)));
      expect(
        (await sharing.journey(
          bookingRef: trip.ref,
          userId: trip.userId,
          now: DateTime.now().toUtc(),
        )),
        isNotNull,
      );
    });
  });
}
