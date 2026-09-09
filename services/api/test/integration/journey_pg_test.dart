@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_disruptions.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_trip_sharing.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// J6 — the passenger sees their own coach move.
///
/// `followed_trip()` has been able to answer this since 0043 and can only be
/// asked by somebody holding a share token. The person with the most reason
/// to want it — sitting on the coach, phone in hand — was the only one who
/// could not ask, unless they happened to have minted a link for a relative.
///
/// Four claims, and they are the whole slice:
///
///   * a passenger sees the road **with no share link minted**;
///   * somebody whose booking was cancelled sees none of it, refused by the
///     row-level rule in 0051 rather than by a clause in Dart;
///   * the tier is `schedule` until a conductor has actually confirmed
///     something, and says so;
///   * the bar never walks backwards past a confirmed place.
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
  late PostgresTripSharing sharing;
  late PostgresOperatorConsole console;
  late PostgresDisruptions desk;
  late String staffId;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(61)),
    );
    desk = PostgresDisruptions(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(63)),
    );
    sharing = PostgresTripSharing(db, random: Random(67));
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    staffId = await fixture.traveller('journey-actor', name: 'Régulateur');
    stationId = await fixture.station('BZV', 'Agence trajet');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  final now = DateTime.now().toUtc();

  /// A paid seat on a road with two named places, and the console the
  /// conductor's handset talks to.
  Future<
    ({
      String ref,
      String bookingId,
      String travellerId,
      String depId,
      List<Waypoint> road,
    })
  >
  trip({bool pay = true}) async {
    final routeId = await fixture.route(
      code: 'JRN-${DateTime.now().microsecondsSinceEpoch}',
      destination: 'PNR',
    );
    await fixture.stopsOn(routeId, const [
      (city: 'OYO', offsetMinutes: 150),
      (city: 'DOL', offsetMinutes: 300),
    ]);
    final departureId = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(hours: 1),
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
    if (pay) {
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
    }
    return (
      ref: booking.ref.value,
      bookingId: booking.id,
      travellerId: await fixture.purchaserOf(booking.id),
      depId: departureId,
      road:
          (await console.waypoints(
            operatorId: PgFixture.operatorId,
            departureId: departureId,
          ))!,
    );
  }

  Future<void> confirm(String departureId, String stopId, DateTime at) =>
      console
          .confirmPassage(
            operatorId: PgFixture.operatorId,
            departureId: departureId,
            reportedByUserId: staffId,
            passages: [
              PassageReport(stopId: stopId, passedAt: at, deviceId: 'handset'),
            ],
          )
          .then((_) {});

  group('the passenger reads their own coach', () {
    test('without ever minting a share link', () async {
      final t = await trip();

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      expect(journey, isNotNull);
      // The point of the slice. A passenger holding a ticket needs no link to
      // see where their coach is, and none was created to give them one.
      expect(await fixture.shareCount(t.bookingId), 0);
    });

    test('the road comes back in the order it is driven', () async {
      final t = await trip();

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      expect(journey!.stops.map((s) => s.name), ['Oyo', 'Dolisie']);
      expect(journey.stops.first.offsetMinutes, 150);
      expect(journey.stops.every((s) => s.passedAt == null), isTrue);
    });

    test('with nothing confirmed, it is an estimate and says so', () async {
      final t = await trip();

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      // ADR-0014's third tier. The screen renders this as *aucune position
      // n'a été signalée*, and the whole reason the tier is on the wire is
      // that it must not be able to render as anything else.
      expect(journey!.progress.tier, TrackingTier.schedule);
      expect(journey.progress.isEstimate, isTrue);
      expect(journey.progress.checkpointName, isNull);
      expect(journey.progress.reportedAt, isNull);
    });

    test('one tap moves it off the estimate', () async {
      final t = await trip();
      final passedAt = now.subtract(const Duration(minutes: 20));
      await confirm(t.depId, t.road.first.stopId, passedAt);

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      expect(journey!.progress.tier, TrackingTier.checkpoint);
      expect(journey.progress.checkpointName, 'Oyo');
      // The conductor's clock, not ours. It is the only one that was at the
      // roadside.
      expect(
        journey.progress.reportedAt!.difference(passedAt).inSeconds.abs(),
        lessThan(2),
      );
      expect(journey.stops.first.passedAt, isNotNull);
      expect(journey.stops.last.passedAt, isNull);
    });

    test('the furthest place down the road wins, not the last tap', () async {
      final t = await trip();
      // Dolisie first, then Oyo — a conductor remembering the earlier stop
      // after passing the later one, which happens on a handset that has been
      // in a dead zone since breakfast.
      await confirm(
        t.depId,
        t.road.last.stopId,
        now.subtract(const Duration(minutes: 10)),
      );
      await confirm(
        t.depId,
        t.road.first.stopId,
        now.subtract(const Duration(minutes: 5)),
      );

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      // How far along a coach is is a fact about the road. A bar that walked
      // backwards after a tap would make the tap look like a mistake.
      expect(journey!.progress.checkpointName, 'Dolisie');
    });

    test('a declared delay is what the estimate is measured from', () async {
      final t = await trip();
      final revised = now.add(const Duration(hours: 3));

      await desk.declare(
        operatorId: PgFixture.operatorId,
        departureId: t.depId,
        kind: DisruptionKind.delay,
        cause: DisruptionCause.mechanical,
        actorUserId: staffId,
        revisedDepartsAt: revised,
        now: now,
      );

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      expect(journey!.revisedDepartsAt, isNotNull);
      // An estimate drawn from a departure that did not happen is worse than
      // no estimate: the coach has not left, so it is at the origin.
      expect(journey.progress.fraction, 0);
    });

    test('a road with no intermediate stops is still a journey', () async {
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 1),
      );
      final booking = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '1A',
        name: 'Serge N.',
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

      final journey = await sharing.journey(
        bookingRef: booking.ref.value,
        userId: await fixture.purchaserOf(booking.id),
        now: now,
      );

      // Brazzaville to Pointe-Noire direct is a real road. An empty stop list
      // and an honest estimate, rather than nothing at all.
      expect(journey, isNotNull);
      expect(journey!.stops, isEmpty);
      expect(journey.progress.tier, TrackingTier.schedule);
    });
  });

  group('who reads nothing', () {
    test('a booking that was cancelled', () async {
      final t = await trip();
      await confirm(t.depId, t.road.first.stopId, now);
      await fixture.setBookingState(t.bookingId, 'cancelled');

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      // Somebody who cancelled last week is not on that coach, and where it
      // has got to stopped being their business. Refused by the schema.
      expect(journey, isNull);
    });

    test('a reservation nobody has paid for', () async {
      final t = await trip(pay: false);

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: t.travellerId,
        now: now,
      );

      expect(journey, isNull);
    });

    test('somebody else, holding the reference', () async {
      final t = await trip();
      final stranger = await fixture.traveller(
        'journey-stranger-${DateTime.now().microsecondsSinceEpoch}',
        name: 'Curieux',
      );

      final journey = await sharing.journey(
        bookingRef: t.ref,
        userId: stranger,
        now: now,
      );

      // The reference is short and read aloud over bad lines. Row-level
      // security is what makes that safe, not the length of the string.
      expect(journey, isNull);
    });

    test('a reference nobody ever issued', () async {
      final t = await trip();

      final journey = await sharing.journey(
        bookingRef: 'ZZZZZZ',
        userId: t.travellerId,
        now: now,
      );

      expect(journey, isNull);
    });
  });

  group('the checkpoints a passenger may read', () {
    test('are only those of coaches they are actually on', () async {
      final mine = await trip();
      final theirs = await trip();
      await confirm(theirs.depId, theirs.road.first.stopId, now);

      // The traveller on the first coach asks about their own journey, whose
      // road has had nothing confirmed on it. If the policy leaked, the
      // second coach's checkpoint would be visible to this transaction and
      // the two roads share nothing but the table.
      final journey = await sharing.journey(
        bookingRef: mine.ref,
        userId: mine.travellerId,
        now: now,
      );

      expect(journey!.stops.every((s) => s.passedAt == null), isTrue);
      expect(journey.progress.tier, TrackingTier.schedule);
    });
  });
}
