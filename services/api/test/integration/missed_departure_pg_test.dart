@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_reschedules.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The passenger who missed their coach, at a counter, against real SQL.
///
/// What only a database can prove here:
///
///   * the later coach may be on a **different route row** — which is how a
///     departure from the operator's other terminal is offered at all;
///   * the fee lands in the **till that took it**, and the ledger balances;
///   * the seats move under a lock and the ticket is re-signed, so a
///     passenger cannot hold a QR for a coach they are no longer on;
///   * an operator who never agreed to this is refused, whatever an agent
///     types.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorConsole console;
  late PostgresBookingStore bookings;
  late PostgresReschedules desk;
  late String operatorId;
  late String staffId;
  late String stationId;

  /// This suite's **own** road. Every other integration suite sells on the
  /// fixture's BZV→PNR route, and the change desk shows the twenty soonest
  /// coaches on the road a booking is already on — so a suite that parks
  /// seven extra departures four hours out on the shared road quietly evicts
  /// another suite's target from its own screen. BZV→DOL belongs to nobody
  /// else, and the city pair is all this feature matches on anyway.
  late String road;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(71)),
    );
    desk = PostgresReschedules(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(71)),
    );
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('missed-actor', name: 'Vendeur');
    stationId = await fixture.station('BZV', 'Guichet Reports');
    road = await fixture.route(
      code: 'BZV-DOL-M${DateTime.now().microsecondsSinceEpoch}',
      destination: 'DOL',
    );
  });

  tearDownAll(() async {
    // Every coach this suite backdated is put back in front of us, so the
    // worker's on-time figure — which rewrites the operator's past — finds
    // the history it expects rather than ours.
    await fixture.undepartRoad(road);
    await db.close();
    await fixture.close();
  });

  Future<void> sellUnder(MissedPolicy missed) async {
    final stored = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Missed ${DateTime.now().microsecondsSinceEpoch}',
      policy: RefundPolicy.souple(),
      actorUserId: staffId,
      missed: missed,
    );
    await console.setDefaultRefundPolicy(
      operatorId: operatorId,
      policyId: stored.id,
      version: stored.version,
    );
  }

  /// A paid booking on a coach that has already left, and a later one to
  /// offer. [targetRoute] puts the later coach on another route row, which is
  /// what a second terminal in the same city looks like in this schema.
  Future<({String ref, String id, String from, String target})> missed({
    Duration since = const Duration(minutes: 40),
    int fareMinor = 12000,
    int targetFareMinor = 12000,
    Duration targetLead = const Duration(hours: 4),
    List<String> targetSeats = const ['5A', '5B'],
    String? targetRoute,
    String targetStatus = 'scheduled',
  }) async {
    // Sold while the coach was still there, then let go: a seat cannot be
    // held on a departure that has already left, and the real path is right
    // to refuse it.
    final departureId = await fixture.departure(
      seatLabels: ['1A'],
      fromNow: const Duration(hours: 2),
      fareMinor: fareMinor,
      onRoute: road,
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
      operatorId: operatorId,
      stationId: stationId,
      soldByUserId: staffId,
      posting: Postings.cashSale(
        operatorId: operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: const Money.xaf(300),
      ).valueOrNull!,
    );

    await fixture.departLongAgo(departureId, since);

    final target = await fixture.departure(
      seatLabels: targetSeats,
      fromNow: targetLead,
      fareMinor: targetFareMinor,
      status: targetStatus,
      onRoute: targetRoute ?? road,
    );

    return (
      ref: booking.ref.value,
      id: booking.id,
      from: departureId,
      target: target,
    );
  }

  group('the counter screen', () {
    test('an operator who never agreed to this offers nothing', () async {
      await sellUnder(MissedPolicy.notOffered);
      final trip = await missed();

      final screen = await desk.missedOptions(
        bookingRef: trip.ref,
        operatorId: operatorId,
        now: DateTime.now().toUtc(),
      );

      // Not "too late" and not an empty list — a named refusal, because an
      // agent whose company has never offered this needs a different sentence
      // from one whose passenger arrived a day late.
      expect(screen!.refusal, isA<MissedNotOffered>());
      expect(screen.options, isEmpty);
    });

    test('every row carries its price and its yard', () async {
      await sellUnder(
        const MissedPolicy(window: Duration(hours: 12), feeBps: 2500),
      );
      final trip = await missed(targetFareMinor: 14000);

      final kinsoundi = await fixture.station(
        'BZV',
        'Gare de Kinsoundi',
        boardingNotes: 'Guichet 3',
      );
      await fixture.setStations(trip.target, origin: kinsoundi);

      final screen = await desk.missedOptions(
        bookingRef: trip.ref,
        operatorId: operatorId,
        now: DateTime.now().toUtc(),
      );
      final row = screen!.options.firstWhere(
        (o) => o.departureId == trip.target,
      );

      expect(screen.refusal, isNull);
      // 25% of 12 000 plus the 2 000 the newer coach costs more.
      expect(row.quote!.fee, const Money.xaf(3000));
      expect(row.quote!.fareDifference, const Money.xaf(2000));
      expect(row.quote!.owed, const Money.xaf(5000));
      expect(row.stationName, 'Gare de Kinsoundi');
      expect(row.boardingNotes, 'Guichet 3');
    });

    test(
      'a coach from the other gare is offered, and marked as such',
      () async {
        await sellUnder(const MissedPolicy(window: Duration(hours: 12)));

        final mikalou = await fixture.station('BZV', 'Gare de Mikalou');
        final kinsoundi = await fixture.station('BZV', 'Gare de Kinsoundi');

        // A second route row between the same two cities — which is exactly
        // what a company's second Brazzaville terminal is in this schema.
        final otherRoute = await fixture.route(
          code: 'BZV2-DOL-${DateTime.now().microsecondsSinceEpoch}',
          destination: 'DOL',
        );
        final trip = await missed(targetRoute: otherRoute);
        await fixture.setStations(trip.from, origin: mikalou);
        await fixture.setStations(trip.target, origin: kinsoundi);

        final screen = await desk.missedOptions(
          bookingRef: trip.ref,
          operatorId: operatorId,
          now: DateTime.now().toUtc(),
        );
        final row = screen!.options.firstWhere(
          (o) => o.departureId == trip.target,
        );

        expect(screen.fromStationName, 'Gare de Mikalou');
        // The whole point: a different route row is still the same journey, and
        // the row says the yard has changed so an agent can say it out loud.
        expect(row.sameStation, isFalse);
        expect(row.stationName, 'Gare de Kinsoundi');
      },
    );
  });

  group('moving them', () {
    test(
      'the seats move, the ticket is re-signed, the till takes the fee',
      () async {
        await sellUnder(
          const MissedPolicy(window: Duration(hours: 12), feeBps: 2500),
        );
        final trip = await missed();
        final before = await fixture.accountBalance(
          'cash:$operatorId:$stationId:till',
        );

        final outcome = await desk.moveMissed(
          bookingRef: trip.ref,
          operatorId: operatorId,
          toDepartureId: trip.target,
          actorUserId: staffId,
          now: DateTime.now().toUtc(),
          stationId: stationId,
        );

        expect(outcome!.refusal, isNull);
        expect(outcome.moved!.paid, const Money.xaf(3000));
        expect(await fixture.departureOf(trip.id), trip.target);
        // The old seat is on sale again and the new one is sold, in the same
        // transaction: a passenger holding both would be a passenger the
        // manifest counts twice.
        expect(await fixture.seatStateOn(trip.from, '1A'), 'available');
        expect(
          await fixture.seatState(trip.id, outcome.moved!.seatLabels.single),
          'sold',
        );
        expect(
          await fixture.accountBalance('cash:$operatorId:$stationId:till'),
          before + 3000,
        );
      },
    );

    test(
      'a free transfer needs no drawer, and a paid one refuses without one',
      () async {
        await sellUnder(const MissedPolicy(window: Duration(hours: 12)));
        final free = await missed();

        final moved = await desk.moveMissed(
          bookingRef: free.ref,
          operatorId: operatorId,
          toDepartureId: free.target,
          actorUserId: staffId,
          now: DateTime.now().toUtc(),
        );
        expect(moved!.moved!.paid, const Money.xaf(0));

        await sellUnder(
          const MissedPolicy(window: Duration(hours: 12), feeBps: 2500),
        );
        final paid = await missed();

        final refused = await desk.moveMissed(
          bookingRef: paid.ref,
          operatorId: operatorId,
          toDepartureId: paid.target,
          actorUserId: staffId,
          now: DateTime.now().toUtc(),
        );

        // Cash in a drawer has to say which drawer. The database says so too;
        // this refusal is what stops an agent discovering it as a 500.
        expect(refused!.refusal, isA<MissedNeedsATill>());
        expect(await fixture.departureOf(paid.id), paid.from);
      },
    );

    test('another company is a new purchase, not a transfer', () async {
      await sellUnder(const MissedPolicy(window: Duration(hours: 12)));
      final trip = await missed();
      final theirs = await fixture.foreignDeparture(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 5),
      );

      final refused = await desk.moveMissed(
        bookingRef: trip.ref,
        operatorId: operatorId,
        toDepartureId: theirs,
        actorUserId: staffId,
        now: DateTime.now().toUtc(),
        stationId: stationId,
      );

      expect(refused!.refusal, isA<ChangeOffRoute>());
      expect(await fixture.departureOf(trip.id), trip.from);
    });

    test('past the window nobody moves, whatever the agent presses', () async {
      await sellUnder(const MissedPolicy(window: Duration(hours: 1)));
      final trip = await missed(since: const Duration(hours: 3));

      final refused = await desk.moveMissed(
        bookingRef: trip.ref,
        operatorId: operatorId,
        toDepartureId: trip.target,
        actorUserId: staffId,
        now: DateTime.now().toUtc(),
      );

      // Re-quoted under the lock rather than trusted from the screen: the row
      // was priced before an agent read it aloud and took somebody's money.
      expect(refused!.refusal, isA<MissedWindowClosed>());
      expect(await fixture.departureOf(trip.id), trip.from);
    });

    test('what happened is written down, drawer included', () async {
      await sellUnder(
        const MissedPolicy(window: Duration(hours: 12), feeBps: 1000),
      );
      final trip = await missed();

      await desk.moveMissed(
        bookingRef: trip.ref,
        operatorId: operatorId,
        toDepartureId: trip.target,
        actorUserId: staffId,
        now: DateTime.now().toUtc(),
        stationId: stationId,
      );

      // The row somebody reads six weeks later when a passenger says they
      // were charged twice.
      final record = await fixture.missedTransferFor(trip.id);
      expect(record, isNotNull);
      expect(record!['paid_minor'], 1200);
      expect(record['fee_minor'], 1200);
      expect(record['difference_minor'], 0);
      expect(record['station_id'].toString(), stationId);
      expect(record['to_departure_id'].toString(), trip.target);
    });
  });
}
