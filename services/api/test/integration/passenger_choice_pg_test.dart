@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_disruptions.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_passenger_choices.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The passenger's own choice (`08-disruption.md` §3.2), against the database
/// that has to make it safe.
///
/// The domain suite proves which options exist and when they close. This file
/// exists for the claims only Postgres can make: that a traveller sees their
/// own booking and nobody else's, that taking a seat and giving one up is one
/// atomic movement in that order, that **the seat they release goes back on
/// sale** — which is the entire argument for building this screen — and that
/// a transaction running with the privilege to write any operator's rows
/// re-checks every fact that made this passenger entitled.
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
  late PostgresDisruptions desk;
  late PostgresPassengerChoices choices;
  late String operatorId;
  late String dispatcherId;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(71)),
    );
    desk = PostgresDisruptions(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(73)),
    );
    choices = PostgresPassengerChoices(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(79)),
      random: Random(83),
    );
    operatorId = PgFixture.operatorId;
    dispatcherId = await fixture.traveller('choice-actor', name: 'Régulateur');
    stationId = await fixture.station('BZV', 'Agence choix');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A paid passenger on a departure, and a later one on the same road with
  /// room on it.
  Future<
    ({
      String ref,
      String bookingId,
      String travellerId,
      String departureId,
      String laterId,
    })
  >
  stranded({
    Duration lead = const Duration(hours: 8),
    Duration later = const Duration(hours: 12),
    List<String> laterSeats = const ['1A', '1B', '1C'],
    String seat = '1A',
    List<String> seats = const ['1A', '1B'],
  }) async {
    // Its own road, per call. Every other suite in this file's database puts
    // departures on the shared BZV–PNR route, and a screen that offers "the
    // next eight coaches" would be offering theirs — which is correct product
    // behaviour and useless as a fixture.
    final routeId = await fixture.route(
      code: 'CHOICE-${DateTime.now().microsecondsSinceEpoch}',
      destination: 'PNR',
    );
    final departureId = await fixture.departure(
      seatLabels: seats,
      fromNow: lead,
      fareMinor: 9000,
      onRoute: routeId,
    );
    final laterId = await fixture.departure(
      seatLabels: laterSeats,
      fromNow: later,
      fareMinor: 12000,
      onRoute: routeId,
    );
    final booking = await fixture.reserve(
      db: db,
      bookings: bookings,
      departureId: departureId,
      seatLabel: seat,
      name: 'Aline M.',
    );
    await bookings.captureCash(
      bookingId: booking.id,
      operatorId: operatorId,
      stationId: stationId,
      soldByUserId: dispatcherId,
      posting: Postings.cashSale(
        operatorId: operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );
    return (
      ref: booking.ref.value,
      bookingId: booking.id,
      travellerId: await fixture.purchaserOf(booking.id),
      departureId: departureId,
      laterId: laterId,
    );
  }

  Future<void> breakDown(String departureId) async {
    final declared = await desk.declare(
      operatorId: operatorId,
      departureId: departureId,
      kind: DisruptionKind.breakdownEnRoute,
      cause: DisruptionCause.mechanical,
      actorUserId: dispatcherId,
      now: DateTime.now().toUtc(),
    );
    expect(declared.valueOrNull, isNotNull);
  }

  group('the screen', () {
    test('offers what they have, what else runs, and the money', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final screen = await choices.optionsFor(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: DateTime.now().toUtc(),
      );

      expect(screen!.open, isTrue);
      // Order is the design: the safe state first, so it is read before any
      // decision is made, and the refund last and never hidden.
      expect(screen.options.first.assigned, isTrue);
      expect(screen.options.last.isRefund, isTrue);
      expect(screen.options.first.seatLabels, ['1A']);

      final later = screen.options
          .where((o) => o.departureId == trip.laterId)
          .single;
      expect(later.seatsAvailable, 3);
      // Every travel row carries an arrival time, because that is what
      // somebody stranded is actually asking about.
      expect(later.arrivesAt, isNotNull);

      // The platform floor: fare plus service fee, whatever the operator's
      // policy says (ADR-0015 rule 4).
      expect(screen.options.last.amount, const Money.xaf(9300));
    });

    test('states the fallback, and when it takes over', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final screen = await choices.optionsFor(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: DateTime.now().toUtc(),
      );

      // An hour before their own coach leaves, and what happens then is the
      // seat they already hold. Ambiguity at 04:00 is worse than a rule
      // somebody dislikes.
      expect(screen!.fallback!.assigned, isTrue);
      expect(
        screen.deadline.isBefore(
          DateTime.now().toUtc().add(const Duration(hours: 8)),
        ),
        isTrue,
      );
    });

    test(
      'a journey nothing is happening to renders, and offers nothing',
      () async {
        final trip = await stranded();

        final screen = await choices.optionsFor(
          bookingRef: trip.ref,
          userId: trip.travellerId,
          now: DateTime.now().toUtc(),
        );

        // Not a 404: a passenger who follows a link and finds nothing assumes
        // the worst. The journey renders and there is nothing to press.
        expect(screen!.open, isFalse);
        expect(
          screen.options.where((o) => o.kind == TravelChoiceKind.move),
          isEmpty,
        );
        expect(screen.originCity, 'BZV');
      },
    );

    test("somebody else's reference is not found, not refused", () async {
      final trip = await stranded();
      await breakDown(trip.departureId);
      final stranger = await fixture.traveller('choice-stranger');

      // The same answer a reference that does not exist gets. Anything else
      // is an endpoint that tells a stranger which references are real.
      expect(
        await choices.optionsFor(
          bookingRef: trip.ref,
          userId: stranger,
          now: DateTime.now().toUtc(),
        ),
        isNull,
      );
    });

    test('a coach that has already gone is never offered', () async {
      final trip = await stranded(
        lead: const Duration(hours: 6),
        later: const Duration(hours: 2),
      );
      await breakDown(trip.departureId);

      final screen = await choices.optionsFor(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: DateTime.now().toUtc(),
      );

      // It leaves before theirs does, but it is still in the future — the
      // rule is measured from now, not from the broken departure, because a
      // coach that failed at 09:00 can genuinely take the 11:00.
      expect(
        screen!.options.where((o) => o.departureId == trip.laterId),
        hasLength(1),
      );
    });

    test('and neither is a full one', () async {
      final trip = await stranded(laterSeats: const ['1A']);
      await breakDown(trip.departureId);

      // Sell the only seat on the later coach out from under them.
      final other = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: trip.laterId,
        seatLabel: '1A',
        name: 'Quelqu un',
      );
      expect(other.id, isNotEmpty);

      final screen = await choices.optionsFor(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: DateTime.now().toUtc(),
      );

      // An option the server would refuse is worse than one never drawn: by
      // the time they find out, they have told somebody they have a coach.
      expect(
        screen!.options.where((o) => o.departureId == trip.laterId),
        isEmpty,
      );
    });
  });

  group('choosing to move', () {
    test(
      'takes the new seat, releases the old one, re-signs the ticket',
      () async {
        final trip = await stranded();
        await breakDown(trip.departureId);

        final result = await choices.choose(
          bookingRef: trip.ref,
          userId: trip.travellerId,
          optionId: trip.laterId,
          now: DateTime.now().toUtc(),
        );

        expect(result.refusal, isNull);
        expect(result.applied!.kind, TravelChoiceKind.move);
        expect(result.applied!.seatLabels, ['1A']);
        expect(await fixture.departureOf(trip.bookingId), trip.laterId);

        // **The seat they gave up is back on sale.** This is the whole argument
        // for the screen: it goes back into the pool for somebody still
        // standing at the roadside.
        final old = await fixture.seatStates(trip.departureId);
        expect(old['1A'], 'available');
        final taken = await fixture.seatStates(trip.laterId);
        expect(taken['1A'], 'sold');

        // The QR carries the seat and the departure (ADR-0007), so an old
        // ticket scans as somebody else's seat at the door.
        expect(await fixture.ticketSeats(trip.bookingId), ['1A']);
        expect(await fixture.ticketCount(trip.bookingId), 1);
      },
    );

    test('carries the fare across, even onto a dearer coach', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: trip.laterId,
        now: DateTime.now().toUtc(),
      );

      // The later coach is a 12 000 departure and they paid 9 000. An
      // involuntary change never costs a fare difference (ADR-0016), and it
      // does not become one because the passenger picked the coach.
      // The coach they moved onto sells its seats at 12 000…
      final seats = await fixture.seatFares(trip.laterId);
      expect(seats['1A'], 12000);
      // …and what this passenger is recorded as having paid for theirs is
      // still the 9 000 they paid.
      expect(await fixture.seatFareOnBooking(trip.bookingId), 9000);
    });

    test('queues the message, and never sends it inline', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: trip.laterId,
        now: DateTime.now().toUtc(),
      );

      // The same event the dispatcher's wave queues: it is the same fact
      // from the passenger's side (ADR-0019).
      expect(await fixture.outboxCount('booking.rebooked', trip.bookingId), 1);
    });

    test('a coach that filled while they were reading says so', () async {
      final trip = await stranded(laterSeats: const ['1A']);
      await breakDown(trip.departureId);

      final screen = await choices.optionsFor(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: DateTime.now().toUtc(),
      );
      expect(
        screen!.options.where((o) => o.departureId == trip.laterId),
        hasLength(1),
      );

      // Somebody else takes the last seat between the read and the tap.
      await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: trip.laterId,
        seatLabel: '1A',
        name: 'Plus rapide',
      );

      final result = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: trip.laterId,
        now: DateTime.now().toUtc(),
      );

      expect(result.refusal, isA<ChoiceNoLongerAvailable>());
      // And they are exactly where they were, which is a seat.
      expect(await fixture.departureOf(trip.bookingId), trip.departureId);
    });
  });

  group('choosing the money', () {
    test('voids the ticket, frees the seat and issues a claim', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final result = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: 'refund',
        now: DateTime.now().toUtc(),
      );

      expect(result.refusal, isNull);
      expect(result.applied!.refunded, const Money.xaf(9300));
      // Collected in cash at a counter. Rail disbursement is a separately
      // funded float that does not exist, and a code says where the money is
      // rather than promising it went somewhere.
      expect(result.applied!.claimCode, isNotNull);

      expect(await fixture.bookingState(trip.ref), 'refunded');
      expect(await fixture.voidedTickets(trip.bookingId), 1);
      final seats = await fixture.seatStates(trip.departureId);
      expect(seats['1A'], 'available');
      expect(await fixture.refundCount(trip.bookingId), 1);
    });

    test('posts a balanced movement and takes no fee', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final before = await fixture.balanceOf(LedgerAccount.revenueServiceFee);

      await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: 'refund',
        now: DateTime.now().toUtc(),
      );

      // The fee comes back too: an operator-caused refund is not a fee we
      // keep (ADR-0015 rule 4).
      expect(
        await fixture.balanceOf(LedgerAccount.revenueServiceFee),
        before - 300,
      );
      expect(await fixture.unbalancedTxnCount(), 0);
    });

    test('queues the code, because a code shown once is a code lost', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: 'refund',
        now: DateTime.now().toUtc(),
      );

      expect(await fixture.outboxCount('booking.refunded', trip.bookingId), 1);
    });

    test('twice is once', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final first = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: 'refund',
        now: DateTime.now().toUtc(),
      );
      final second = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: 'refund',
        now: DateTime.now().toUtc(),
      );

      expect(first.applied, isNotNull);
      // A dropped connection and a second tap is one refund, not two.
      expect(second.refusal, isNotNull);
      expect(await fixture.refundCount(trip.bookingId), 1);
    });
  });

  group('the escalation re-checks what it would otherwise trust', () {
    test('a stranger cannot move somebody else\'s booking', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);
      final stranger = await fixture.traveller('choice-thief');

      final result = await choices.choose(
        bookingRef: trip.ref,
        userId: stranger,
        optionId: trip.laterId,
        now: DateTime.now().toUtc(),
      );

      expect(result.refusal, isA<NothingDisrupted>());
      expect(await fixture.departureOf(trip.bookingId), trip.departureId);
    });

    test(
      'a passenger nobody disrupted cannot refund themselves free',
      () async {
        final trip = await stranded();

        // No declaration: the exemption is not on their booking, so the
        // platform floor does not apply to them and this screen is not theirs.
        final result = await choices.choose(
          bookingRef: trip.ref,
          userId: trip.travellerId,
          optionId: 'refund',
          now: DateTime.now().toUtc(),
        );

        expect(result.refusal, isA<NothingDisrupted>());
        expect(await fixture.bookingState(trip.ref), 'confirmed');
      },
    );

    test('and neither can somebody whose deadline passed', () async {
      final trip = await stranded(lead: const Duration(minutes: 40));
      await breakDown(trip.departureId);

      // The disruption was called in forty minutes before departure, so the
      // window was never open. The fallback stands, and it is a seat.
      final result = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: trip.laterId,
        now: DateTime.now().toUtc(),
      );

      expect(result.refusal, isA<ChoiceWindowClosed>());
      expect(await fixture.departureOf(trip.bookingId), trip.departureId);
    });

    test('an option nobody offered is not found', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final result = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: '99999999-9999-9999-9999-999999999999',
        now: DateTime.now().toUtc(),
      );

      expect(result.refusal, isA<UnknownChoice>());
    });
  });

  group('keeping what you have', () {
    test('writes nothing, and says so', () async {
      final trip = await stranded();
      await breakDown(trip.departureId);

      final result = await choices.choose(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        optionId: 'keep',
        now: DateTime.now().toUtc(),
      );

      // A real answer: the tap is how somebody stops worrying, and it must
      // not cost them their seat to press it.
      expect(result.refusal, isNull);
      expect(result.applied!.kind, TravelChoiceKind.keep);
      expect(result.applied!.seatLabels, ['1A']);
      expect(await fixture.departureOf(trip.bookingId), trip.departureId);
      expect(await fixture.bookingState(trip.ref), 'confirmed');
    });
  });
}
