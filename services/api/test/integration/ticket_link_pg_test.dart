@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_ticket_links.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The ticket you can always get to (ADR-0026), against a real database.
///
/// The claims worth making here cannot be made against a fake: that the token
/// is stored as a hash and nothing else, that an anonymous caller can resolve
/// one and cannot list them, and that a revoked link, an expired link and a
/// token nobody ever issued are the same answer.
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
  late PostgresTicketLinks links;
  late String stationId;
  late String roadId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(31)),
    );
    links = PostgresTicketLinks(db, linkBase: Uri.parse('https://blt.cg'));
    stationId = await fixture.station('BZV', 'Agence Lien');
    roadId = await fixture.route(code: 'LINK', destination: 'OYO');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  final now = DateTime.utc(2026, 8, 15, 6);

  /// A paid booking, which is the only kind that has a ticket to link to.
  Future<({String id, String ref})> aPaidBooking() async {
    final departureId = await fixture.departure(
      seatLabels: const ['1A'],
      onRoute: roadId,
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
      soldByUserId: null,
      posting: Postings.cashSale(
        operatorId: PgFixture.operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );
    return (id: booking.id, ref: booking.ref.value);
  }

  /// What the drain does, without standing the worker up: mint the link.
  Future<String> mintFor(String bookingId, {String channel = 'email'}) async {
    late String token;
    await db.transaction(const DbScope.worker(), (tx) async {
      final minted = await links.mintInto(
        tx,
        bookingId: bookingId,
        channel: channel,
        sentTo: 'walkin@example.cg',
      );
      token = minted!.token;
    });
    return token;
  }

  group('the vendor asks for it to be sent', () {
    test('a paid booking queues a send, and no token exists yet', () async {
      final booking = await aPaidBooking();

      final queued = await links.queueSend(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        channel: 'email',
        sendTo: 'walkin@example.cg',
        byUserId: null,
        now: now,
      );

      expect(queued.valueOrNull!.sentTo, 'walkin@example.cg');

      // Queued, not minted. The token is created by the drain, in the
      // transaction that composes the message — so a queue row is never a
      // working link into somebody's ticket.
      final rows = await fixture.rows(
        'SELECT count(*) AS n FROM ticket_links '
        "WHERE booking_id = '${booking.id}'",
      );
      expect(rows.single['n'], 0);
    });

    test('a reservation nobody paid for has nothing to send', () async {
      final departureId = await fixture.departure(
        seatLabels: const ['2A'],
        onRoute: roadId,
      );
      final unpaid = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '2A',
        name: 'Aline M.',
      );

      final queued = await links.queueSend(
        operatorId: PgFixture.operatorId,
        bookingRef: unpaid.ref.value,
        channel: 'email',
        sendTo: 'walkin@example.cg',
        byUserId: null,
        now: now,
      );

      // A link to an unpaid reservation opens a page with no QR on it, which
      // reads as our failure rather than as an unpaid booking.
      expect(queued.failureOrNull, isA<NothingToSend>());
    });

    test("another operator's booking is not found", () async {
      final booking = await aPaidBooking();

      final queued = await links.queueSend(
        operatorId: '22222222-2222-2222-2222-222222222222',
        bookingRef: booking.ref,
        channel: 'email',
        sendTo: 'walkin@example.cg',
        byUserId: null,
        now: now,
      );

      // Not "not yours": that would confirm the reference exists.
      expect(queued.failureOrNull, isA<UnknownBooking>());
    });

    test('nowhere to send it is refused rather than queued', () async {
      final booking = await aPaidBooking();

      final queued = await links.queueSend(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        channel: 'email',
        sendTo: '   ',
        byUserId: null,
        now: now,
      );

      // The account behind a fixture booking carries a phone, not an email,
      // so there is no address to fall back to — and a queued send with
      // nowhere to go is a customer standing at a counter being told yes.
      expect(queued.failureOrNull, isA<NoDestination>());
    });
  });

  group('the holder opens it', () {
    test('the ticket comes back, QR and all', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      final opened = await links.open(token: token, now: now);

      expect(opened!.bookingRef, booking.ref);
      expect(opened.state, 'confirmed');
      expect(opened.seats.single.seatLabel, '1A');
      // The signed payload itself: this is what a conductor scans, and it
      // verifies with no network at all (ADR-0007).
      expect(opened.seats.single.payload, contains('|'));
      expect(opened.channel, 'email');
    });

    // The address is the fact an agency's telephone line repeats more than
    // any other: which of the company's three yards to stand in at half past
    // five in the morning.
    test("the yard is on it, with the company's own directions", () async {
      final booking = await aPaidBooking();
      final departureId = await fixture.departureOf(booking.id);
      await fixture.rows(
        "UPDATE stations SET boarding_notes = 'Portail vert' "
        "WHERE id = '$stationId'",
      );
      await fixture.rows(
        "UPDATE departures SET origin_station_id = '$stationId' "
        "WHERE id = '$departureId'",
      );
      final token = await mintFor(booking.id);

      final opened = await links.open(token: token, now: now);

      expect(opened!.stationName, 'Agence Lien');
      expect(opened.stationNotes, 'Portail vert');
    });

    // A family of three whose middle ticket was refunded must not find a page
    // with two seats on it and no explanation.
    test('a cancelled seat comes back marked, not missing', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);
      await fixture.rows(
        'UPDATE tickets SET voided_at = now() '
        "WHERE booking_id = '${booking.id}'",
      );

      final opened = await links.open(token: token, now: now);

      expect(opened!.seats.single.seatLabel, '1A');
      expect(opened.seats.single.voided, isTrue);
    });

    test('opening it is counted, so a traveller can see it arrived', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      await links.open(token: token, now: now);
      await links.open(token: token, now: now);

      final rows = await fixture.rows(
        "SELECT opens FROM ticket_links WHERE booking_id = '${booking.id}'",
      );
      expect(rows.single['opens'], 2);
    });

    test('revoked, expired and never-issued are one answer', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      // Never issued.
      expect(await links.open(token: 'not-a-token', now: now), isNull);

      // Expired: the link outlives the coach by a day and no longer.
      expect(
        await links.open(token: token, now: now.add(const Duration(days: 9))),
        isNull,
      );

      await links.revoke(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        now: now,
      );
      expect(await links.open(token: token, now: now), isNull);
    });

    test('the token is nowhere in the database', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      final rows = await fixture.rows(
        'SELECT token_hash FROM ticket_links '
        "WHERE booking_id = '${booking.id}'",
      );

      // A dump, a replica, a backup on somebody's laptop: none of them is a
      // set of working links into people's tickets.
      expect(rows.single['token_hash'], isNot(contains(token)));
      expect(rows.single['token_hash'], PostgresTicketLinks.hashOf(token));
    });

    test('an anonymous caller cannot list the links', () async {
      final booking = await aPaidBooking();
      await mintFor(booking.id);

      // The holder reads through a SECURITY DEFINER function that takes a
      // hash. A SELECT policy here would be row-enumerable, which is a list
      // of every live ticket in the country.
      final visible = await db.transaction(const DbScope.anonymous(), (
        tx,
      ) async {
        final rows = await tx.execute('SELECT count(*) AS n FROM ticket_links');
        return rows.first.toColumnMap()['n'] as int;
      });
      expect(visible, 0);
    });
  });

  // ── Seeing is not changing ────────────────────────────────────────────────
  //
  // ADR-0026. The token opens a ticket and nothing else. Changing one takes a
  // code, and the code goes where the ticket already went.
  group('the holder proves it is them', () {
    test('the code may only go where the link went', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      final destination = await links.destinationFor(token);

      expect(destination!.sentTo, 'walkin@example.cg');
      expect(destination.channel, 'email');
      expect(destination.bookingId, booking.id);
    });

    test('a dead link has nowhere to send anything', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      expect(await links.destinationFor('not-a-token'), isNull);

      await links.revoke(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        now: now,
      );
      expect(await links.destinationFor(token), isNull);
    });

    // Asking for a code is not reading a ticket, and a tally that moved on it
    // would make the open count a lie.
    test('asking where to send is not an open', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);

      await links.destinationFor(token);
      await links.destinationFor(token);

      final rows = await fixture.rows(
        "SELECT opens FROM ticket_links WHERE booking_id = '${booking.id}'",
      );
      expect(rows.single['opens'], 0);
    });

    // The highest-value line in the feature: a walk-in becomes somebody with
    // an account, without anybody selling them anything.
    test('the counter unverified account hands the booking over', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);
      final claimant = await fixture.traveller('claim1', name: 'Aline M.');

      final claimed = await links.claim(token: token, userId: claimant);

      expect(claimed, booking.ref);
      final rows = await fixture.rows(
        "SELECT purchaser_user_id FROM bookings WHERE id = '${booking.id}'",
      );
      expect(rows.single['purchaser_user_id'].toString(), claimant);
    });

    test('claiming twice is claiming once', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);
      final claimant = await fixture.traveller('claim2');

      expect(await links.claim(token: token, userId: claimant), booking.ref);
      expect(await links.claim(token: token, userId: claimant), booking.ref);
    });

    // An account somebody has actually signed in to belongs to a person, and
    // a link is not enough to take their booking away from them.
    test('a booking somebody has proved they hold is not taken', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);
      await fixture.rows(
        'UPDATE user_accounts SET phone_verified_at = now() '
        "WHERE id = (SELECT purchaser_user_id FROM bookings "
        "WHERE id = '${booking.id}')",
      );
      final stranger = await fixture.traveller('claim3');

      expect(await links.claim(token: token, userId: stranger), isNull);
    });

    test('a dead link claims nothing', () async {
      final booking = await aPaidBooking();
      final token = await mintFor(booking.id);
      final claimant = await fixture.traveller('claim4');

      await links.revoke(
        operatorId: PgFixture.operatorId,
        bookingRef: booking.ref,
        now: now,
      );

      expect(await links.claim(token: token, userId: claimant), isNull);
    });
  });
}
