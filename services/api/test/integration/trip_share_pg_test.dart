@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_disruptions.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_trip_sharing.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Sharing a trip (ADR-0014 §2), against the database that has to make it
/// safe for a stranger to read.
///
/// The domain suite proves the window and the progress arithmetic. This file
/// exists for the claims only Postgres can make: that the token is never
/// stored, that a follower with no account resolves a link and a follower
/// with the wrong token resolves nothing, that revoking is immediate and
/// silent, and that what comes back is a coach and never a passenger.
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
  late PostgresTripSharing sharing;
  late String operatorId;
  late String staffId;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(91)),
    );
    desk = PostgresDisruptions(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(93)),
    );
    sharing = PostgresTripSharing(
      db,
      shareBase: Uri.parse('https://blt.cg'),
      random: Random(97),
    );
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('share-actor', name: 'Régulateur');
    stationId = await fixture.station('BZV', 'Agence partage');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  Future<({String ref, String bookingId, String travellerId, String depId})>
  paidTrip({Duration lead = const Duration(hours: 4)}) async {
    final routeId = await fixture.route(
      code: 'SHARE-${DateTime.now().microsecondsSinceEpoch}',
      destination: 'PNR',
    );
    final departureId = await fixture.departure(
      seatLabels: const ['1A', '1B'],
      fromNow: lead,
      fareMinor: 9000,
      onRoute: routeId,
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
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );
    return (
      ref: booking.ref.value,
      bookingId: booking.id,
      travellerId: await fixture.purchaserOf(booking.id),
      depId: departureId,
    );
  }

  final now = DateTime.now().toUtc();

  group('minting a link', () {
    test('a paid trip produces a token, once', () async {
      final trip = await paidTrip();

      final first = await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );
      final again = await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );

      expect(first.valueOrNull?.token, isNotNull);
      // Asking twice hands back the link they already have. A second live one
      // would be a link they cannot see in order to revoke it.
      expect(again.valueOrNull?.token, isNull);
      expect(again.valueOrNull?.expiresAt, first.valueOrNull!.expiresAt);
      expect(await fixture.shareCount(trip.bookingId), 1);
    });

    test('the token itself is never stored', () async {
      final trip = await paidTrip();
      final share = await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );
      final token = share.valueOrNull!.token!;

      // A database dump must not be a set of working links into people's
      // journeys — the same rule a sign-in code lives under.
      expect(
        await fixture.shareTokenHashes(trip.bookingId),
        isNot(contains(token)),
      );
      expect(token.length, greaterThan(20));
    });

    test('an unpaid reservation is not a trip', () async {
      final routeId = await fixture.route(
        code: 'SHARE-U-${DateTime.now().microsecondsSinceEpoch}',
        destination: 'PNR',
      );
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 5),
        fareMinor: 9000,
        onRoute: routeId,
      );
      final booking = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '1A',
        name: 'Aline M.',
      );

      final result = await sharing.share(
        bookingRef: booking.ref.value,
        userId: await fixture.purchaserOf(booking.id),
        now: now,
      );

      // A link that resolved to a reservation somebody may never pay for
      // would quietly stop working when the hold lapsed, which reads to
      // whoever holds it as our bug.
      expect(result.failureOrNull, isA<NothingToShare>());
    });

    test("somebody else's booking is not theirs to share", () async {
      final trip = await paidTrip();
      final stranger = await fixture.traveller('share-stranger');

      final result = await sharing.share(
        bookingRef: trip.ref,
        userId: stranger,
        now: now,
      );

      // Not a 403: under their own tenancy the row is not there at all, so
      // there is nothing to refuse.
      expect(result.failureOrNull, isA<UnknownShare>());
    });

    test('the link dies six hours after arrival', () async {
      final trip = await paidTrip();
      final share = await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );

      final arrives = await fixture.arrivesAt(trip.depId);
      expect(share.valueOrNull!.expiresAt.difference(arrives).inHours, 6);
    });
  });

  group('following one', () {
    test('a stranger with the link sees the coach', () async {
      final trip = await paidTrip();
      final token = (await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      )).valueOrNull!.token!;

      final followed = await sharing.follow(token: token, now: now);

      expect(followed, isNotNull);
      expect(followed!.originCity, 'Brazzaville');
      expect(followed.destinationCity, 'Pointe-Noire');
      expect(followed.operatorName, isNotEmpty);
      // Tier 3 is all we have: no conductor is reporting a position, and the
      // page says so rather than drawing a confident dot.
      expect(followed.progress.tier, TrackingTier.schedule);
      expect(followed.progress.isEstimate, isTrue);
    });

    test(
      'opening it is counted, so the traveller can see it arrived',
      () async {
        final trip = await paidTrip();
        final token = (await sharing.share(
          bookingRef: trip.ref,
          userId: trip.travellerId,
          now: now,
        )).valueOrNull!.token!;

        await sharing.follow(token: token, now: now);
        await sharing.follow(token: token, now: now);

        final mine = await sharing.shareFor(
          bookingRef: trip.ref,
          userId: trip.travellerId,
        );
        expect(mine!.opens, 2);
      },
    );

    test('a token nobody issued resolves to nothing', () async {
      expect(
        await sharing.follow(token: 'not-a-token-anybody-minted', now: now),
        isNull,
      );
    });

    test('a revoked link answers exactly like an unknown one', () async {
      final trip = await paidTrip();
      final token = (await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      )).valueOrNull!.token!;

      await sharing.revoke(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );

      // "This link was revoked" tells whoever holds it that it was once real
      // and that somebody took it away from them — a conversation the
      // traveller did not ask to start.
      expect(await sharing.follow(token: token, now: now), isNull);
    });

    test('and revoking twice is not an error', () async {
      final trip = await paidTrip();
      await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );

      await sharing.revoke(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );
      final second = await sharing.revoke(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );

      // The traveller pressing it again on a bad connection means the same
      // thing both times.
      expect(second.failureOrNull, isNull);
    });

    test('after revoking, sharing again mints a new link', () async {
      final trip = await paidTrip();
      final first = (await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      )).valueOrNull!.token!;

      await sharing.revoke(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );
      final second = await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );

      expect(second.valueOrNull?.token, isNotNull);
      expect(second.valueOrNull!.token, isNot(first));
      // And the old one stays dead. Revocation that a re-share undid would be
      // worse than no revocation at all.
      expect(await sharing.follow(token: first, now: now), isNull);
    });

    test('past the window it stops resolving', () async {
      final trip = await paidTrip();
      final share = await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      );
      final token = share.valueOrNull!.token!;

      expect(
        await sharing.follow(
          token: token,
          now: share.valueOrNull!.expiresAt.add(const Duration(minutes: 1)),
        ),
        isNull,
      );
    });

    test('a breakdown reaches the person waiting at the station', () async {
      final trip = await paidTrip();
      final token = (await sharing.share(
        bookingRef: trip.ref,
        userId: trip.travellerId,
        now: now,
      )).valueOrNull!.token!;

      await desk.declare(
        operatorId: operatorId,
        departureId: trip.depId,
        kind: DisruptionKind.breakdownEnRoute,
        cause: DisruptionCause.mechanical,
        actorUserId: staffId,
        note: 'Panne moteur, un car de secours est parti.',
        now: now,
      );

      final followed = await sharing.follow(token: token, now: now);

      // The follower is exactly the person who otherwise phones the agency,
      // which is the cost this whole subsystem exists to remove.
      expect(followed!.disruptionKind, 'breakdown_en_route');
      expect(followed.disruptionNote, contains('car de secours'));
    });
  });
}
