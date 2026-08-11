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

/// The traveller moving themselves to another departure, against a real
/// database (`01-feature-spec.md` §8.1).
///
/// The clock here is the **real** one, unlike the refund suites: the candidate
/// query filters on Postgres's `now()` and the quote is computed in Dart, and
/// a test that pushed the fake clock two years forward would be asserting
/// about a screen the server would never draw.
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
  late DateTime now;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(53)),
    );
    desk = PostgresReschedules(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(53)),
    );
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('change-actor', name: 'Vendeur');
    stationId = await fixture.station('BZV', 'Agence Changements');
    now = DateTime.now().toUtc();
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// Change terms, stored on a policy and made the operator's default.
  Future<void> sellUnder(ChangePolicy policy) async {
    final stored = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Terms ${DateTime.now().microsecondsSinceEpoch}',
      policy: RefundPolicy.souple(),
      actorUserId: staffId,
      change: policy,
    );
    await console.setDefaultRefundPolicy(
      operatorId: operatorId,
      policyId: stored.id,
      version: stored.version,
    );
  }

  /// A paid booking [lead] from now, and a second departure on the same route
  /// [targetLead] from now with [targetSeats] free.
  Future<({String ref, String id, String from, String userId, String target})>
  sold({
    Duration lead = const Duration(hours: 30),
    Duration targetLead = const Duration(hours: 40),
    int fareMinor = 9000,
    int targetFareMinor = 9000,
    List<String> targetSeats = const ['5A', '5B', '5C'],
    bool fillTarget = false,
    String targetStatus = 'scheduled',
    String? targetRoute,
  }) async {
    final departureId = await fixture.departure(
      seatLabels: ['1A'],
      fromNow: lead,
      fareMinor: fareMinor,
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

    final target = await fixture.departure(
      seatLabels: targetSeats,
      fromNow: targetLead,
      fareMinor: targetFareMinor,
      status: targetStatus,
      onRoute: targetRoute,
    );
    if (fillTarget) await fixture.fillDeparture(target);

    return (
      ref: booking.ref.value,
      id: booking.id,
      from: departureId,
      userId: await fixture.purchaserOf(booking.id),
      target: target,
    );
  }

  group('the screen', () {
    test('every row carries its own price', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(targetFareMinor: 10500);

      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );

      final row = screen!.options.firstWhere(
        (o) => o.departureId == trip.target,
      );
      // Free window — 30 h out — so no fee, and only the difference.
      expect(row.quote!.fee, const Money.xaf(0));
      expect(row.quote!.fareDifference, const Money.xaf(1500));
      expect(row.quote!.owed, const Money.xaf(1500));
      expect(row.arrivesAt.isAfter(row.departsAt), isTrue);
    });

    test('the terms are the ones the booking was sold under', () async {
      await sellUnder(const ChangePolicy(feeBps: 2500));
      final trip = await sold(lead: const Duration(hours: 6));

      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );
      final row = screen!.options.firstWhere(
        (o) => o.departureId == trip.target,
      );
      expect(row.quote!.fee, const Money.xaf(2250));

      // The operator now writes cheaper terms and points the default at them.
      // This booking must not move — ADR-0015 rule 1, for changes.
      await sellUnder(const ChangePolicy(feeBps: 0));

      final again = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );
      expect(
        again!.options
            .firstWhere((o) => o.departureId == trip.target)
            .quote!
            .fee,
        const Money.xaf(2250),
      );
    });

    test(
      'a coach with no room is shown with the reason, not dropped',
      () async {
        await sellUnder(ChangePolicy.standard);
        final trip = await sold(fillTarget: true);

        final screen = await desk.options(
          bookingRef: trip.ref,
          userId: trip.userId,
          now: now,
        );

        final row = screen!.options.firstWhere(
          (o) => o.departureId == trip.target,
        );
        expect(row.refusal, isA<ChangeDoesNotFit>());
        expect(row.seatsAvailable, 0);
      },
    );

    test('another company on another road is not on the list', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final elsewhere = await fixture.foreignDeparture(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 40),
      );

      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );

      expect(
        screen!.options.map((o) => o.departureId),
        isNot(contains(elsewhere)),
      );
    });

    test('inside the cutoff the whole screen is one sentence', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(lead: const Duration(minutes: 30));

      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );

      // One refusal, not the same refusal repeated on eight rows.
      expect(screen!.refusal, isA<ChangeTooLate>());
      expect(screen.options, isEmpty);
    });

    test('a stranger sees nothing, not a refusal', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final stranger = await fixture.traveller('change-stranger');

      expect(
        await desk.options(bookingRef: trip.ref, userId: stranger, now: now),
        isNull,
      );
    });
  });

  group('moving', () {
    test(
      'a free change takes the seats, releases the old and re-signs',
      () async {
        await sellUnder(ChangePolicy.standard);
        final trip = await sold();
        final beforeSeats = await fixture.ticketSeats(trip.id);

        final result = await desk.change(
          bookingRef: trip.ref,
          userId: trip.userId,
          toDepartureId: trip.target,
          now: now,
        );

        expect(result!.applied!.departureId, trip.target);
        expect(result.applied!.seatLabels, ['5A']);
        // The old seat is back on sale in the same transaction.
        expect(await fixture.seatStateOn(trip.from, '1A'), 'available');
        // And the ticket is new, because the QR carries the seat and the
        // departure (ADR-0007).
        expect(await fixture.ticketCount(trip.id), beforeSeats.length);
        expect(await fixture.bookingState(trip.ref), 'confirmed');
      },
    );

    test('a change that owes money is refused with the amount', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(targetFareMinor: 10500);

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      // A movement that left an unpaid difference behind is a passenger with
      // a valid QR and an argument at the door.
      final refusal = result!.refusal;
      expect(refusal, isA<ChangeMustBePaid>());
      expect(refusal!.params['owedMinor'], 1500);
      expect(await fixture.seatStateOn(trip.from, '1A'), 'sold');
    });

    test('a cheaper coach is free and gives nothing back', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(targetFareMinor: 7000);

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      expect(result!.applied, isNotNull);
      // The fare on the manifest is what they paid, not what the new coach
      // sells for. Stated on the row before the tap.
      expect(await fixture.seatFareOnBooking(trip.id), 9000);
    });

    test('another company’s coach is refused', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final elsewhere = await fixture.foreignDeparture(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 40),
      );

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: elsewhere,
        now: now,
      );

      // Refused at the lock, not filtered on the screen: the screen is not
      // what a client has to send.
      expect(result!.refusal, isA<ChangeOffRoute>());
    });

    test('the departure they already hold is refused', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: screen!.currentDepartureId,
        now: now,
      );

      expect(result!.refusal, isA<ChangeToTheSameDeparture>());
    });

    test('a coach with no room refuses, and nothing moves', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(fillTarget: true);

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      expect(result!.refusal, isA<ChangeDoesNotFit>());
      expect(await fixture.seatStateOn(trip.from, '1A'), 'sold');
    });

    test('inside the cutoff it refuses', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(lead: const Duration(minutes: 30));

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      expect(result!.refusal, isA<ChangeTooLate>());
    });

    test('a stranger cannot move somebody else', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final stranger = await fixture.traveller('change-thief');

      final result = await desk.change(
        bookingRef: trip.ref,
        userId: stranger,
        toDepartureId: trip.target,
        now: now,
      );

      // Null, not a refusal — the same answer as a reference that does not
      // exist, so a stranger cannot measure which one they typed.
      expect(result, isNull);
      expect(await fixture.seatStateOn(trip.from, '1A'), 'sold');
    });

    test('the passenger is told, and only once', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      // The same event the dispatcher's wave queues: from the passenger's
      // side it is the same fact. Queued, never sent inline (ADR-0019).
      expect(await fixture.outboxCount('booking.rebooked', trip.id), 1);
    });

    test('the traveller is named as the actor', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      await desk.change(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      final audit = await fixture.auditFor(operatorId);
      expect(
        audit.where((row) => row['action'] == 'booking.self_changed'),
        isNotEmpty,
      );
    });

    test('a party of three moves whole, or not at all', () async {
      await sellUnder(ChangePolicy.standard);

      final departureId = await fixture.departure(
        seatLabels: const ['1A', '1B', '1C'],
        fromNow: const Duration(hours: 30),
        fareMinor: 9000,
      );
      final booking = await fixture.reserveParty(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabels: const ['1A', '1B', '1C'],
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
      final userId = await fixture.purchaserOf(booking.id);

      // Two seats free, three people. Nothing moves, and the number short is
      // in the refusal.
      final tooSmall = await fixture.departure(
        seatLabels: const ['2A', '2B'],
        fromNow: const Duration(hours: 40),
        fareMinor: 9000,
      );

      final refused = await desk.change(
        bookingRef: booking.ref.value,
        userId: userId,
        toDepartureId: tooSmall,
        now: now,
      );
      expect(refused!.refusal, isA<ChangeDoesNotFit>());
      expect(refused.refusal!.params['available'], 2);
      expect(await fixture.seatState(booking.id, '1A'), 'sold');

      final big = await fixture.departure(
        seatLabels: const ['3A', '3B', '3C', '3D'],
        fromNow: const Duration(hours: 44),
        fareMinor: 9000,
      );
      final moved = await desk.change(
        bookingRef: booking.ref.value,
        userId: userId,
        toDepartureId: big,
        now: now,
      );

      expect(moved!.applied!.seatLabels, ['3A', '3B', '3C']);
      expect(await fixture.ticketSeats(booking.id), ['3A', '3B', '3C']);
    });
  });
}
