@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/disruption_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_disruptions.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Declaring a disruption, against the database that has to make it atomic.
///
/// The in-memory domain suite proves which declaration entitles whom. This
/// file exists for the claims a Dart map cannot make: that the record, the
/// departure's new status, the exemption on every booking and one queued
/// message per passenger either all happen or none do; that a second
/// declaration supersedes the first rather than sitting beside it; and that a
/// traveller reading their own booking sees what is happening to their coach.
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
  late String operatorId;
  late String dispatcherId;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(31)),
    );
    desk = PostgresDisruptions(db);
    operatorId = PgFixture.operatorId;
    dispatcherId = await fixture.traveller('irrops-actor', name: 'Régulateur');
    stationId = await fixture.station('BZV', 'Agence IRROPS');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A departure with one paid passenger on it.
  Future<({String departureId, String bookingId, String travellerId})> sold({
    Duration lead = const Duration(hours: 8),
    String seat = '1A',
  }) async {
    final departureId = await fixture.departure(
      seatLabels: [seat],
      fromNow: lead,
      fareMinor: 9000,
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
      departureId: departureId,
      bookingId: booking.id,
      travellerId: await fixture.purchaserOf(booking.id),
    );
  }

  Future<Result<DisruptionRecord, DeclarationRefusal>> declare(
    String departureId, {
    DisruptionKind kind = DisruptionKind.breakdownEnRoute,
    DisruptionCause cause = DisruptionCause.mechanical,
    DateTime? revised,
    String? note,
    String? location,
  }) => desk.declare(
    operatorId: operatorId,
    departureId: departureId,
    kind: kind,
    cause: cause,
    actorUserId: dispatcherId,
    now: DateTime.now().toUtc(),
    revisedDepartsAt: revised,
    note: note,
    location: location,
  );

  test('a breakdown records, exempts and queues, in one transaction', () async {
    final trip = await sold();

    final declared = await declare(
      trip.departureId,
      note: 'moteur, km 180 RN1',
      location: 'RN1 près de Dolisie',
    );

    final record = declared.valueOrNull!;
    expect(record.bookingsAffected, 1);
    expect(record.marksInvoluntary, isTrue);

    // The flag that permanently exempts this booking from fees and fare
    // differences. Written by the same statement that wrote the record —
    // an exemption with no declaration behind it is a refund entitlement
    // nobody can account for.
    expect(await fixture.involuntaryBookings(trip.departureId), 1);

    // And exactly one message queued, per booking, for the drain to deliver
    // in the recipient's own language.
    expect(await fixture.outboxCount('disruption.declared', trip.bookingId), 1);
  });

  test(
    'a short delay tells the passenger and entitles them to nothing',
    () async {
      final trip = await sold();
      final departsAt = await fixture.departsAt(trip.departureId);

      final declared = await declare(
        trip.departureId,
        kind: DisruptionKind.delay,
        cause: DisruptionCause.checkpoint,
        revised: departsAt.add(const Duration(minutes: 20)),
      );

      expect(declared.valueOrNull!.marksInvoluntary, isFalse);
      expect(await fixture.involuntaryBookings(trip.departureId), 0);
      // Told anyway. Twenty minutes is not a free cancellation and it is still
      // twenty minutes somebody would otherwise spend standing at a gare.
      expect(
        await fixture.outboxCount('disruption.declared', trip.bookingId),
        1,
      );
    },
  );

  test('a delay moves the departure the board and the manifest read', () async {
    final trip = await sold();
    final departsAt = await fixture.departsAt(trip.departureId);
    final revised = departsAt.add(const Duration(hours: 2));

    await declare(
      trip.departureId,
      kind: DisruptionKind.delay,
      cause: DisruptionCause.lateInbound,
      revised: revised,
    );

    // A row marked `delayed` that still shows 06:00 tells three surfaces the
    // wrong time — the dispatcher's board, the conductor's manifest and the
    // traveller's own ticket all read `departs_at`.
    expect(await fixture.departureStatus(trip.departureId), 'delayed');
    expect(
      (await fixture.departsAt(trip.departureId)).difference(revised).inMinutes,
      0,
    );
  });

  test('a cancellation cancels the departure', () async {
    final trip = await sold();

    await declare(
      trip.departureId,
      kind: DisruptionKind.cancellation,
      cause: DisruptionCause.noVehicle,
    );

    expect(await fixture.departureStatus(trip.departureId), 'cancelled');
  });

  test('a coach already on the road keeps its status', () async {
    final trip = await sold();
    await fixture.setDepartureStatus(trip.departureId, 'departed');

    await declare(trip.departureId);

    // Putting a coach that is physically between two cities back into a state
    // the board reads as "has not left yet" is how an agency tells a walk-in
    // the wrong thing.
    expect(await fixture.departureStatus(trip.departureId), 'departed');
  });

  test('the second declaration supersedes the first', () async {
    final trip = await sold();

    final first = await declare(trip.departureId);
    final second = await declare(
      trip.departureId,
      kind: DisruptionKind.equipmentSwap,
      cause: DisruptionCause.mechanical,
    );

    // "What is happening to my coach right now?" has exactly one answer, and
    // the partial unique index is what makes that a guarantee rather than an
    // ordering convention.
    final open = await desk.openFor(
      operatorId: operatorId,
      from: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      to: DateTime.now().toUtc().add(const Duration(days: 2)),
    );
    expect(open[trip.departureId]!.id, second.valueOrNull!.id);
    expect(
      await fixture.supersededBy(first.valueOrNull!.id),
      second.valueOrNull!.id,
    );
  });

  test('a declaration cannot be edited afterwards', () async {
    final trip = await sold();
    final declared = await declare(trip.departureId, note: 'moteur');

    // The column grant, from the tenant surface the console actually uses.
    // This is the operator's own evidence in a dispute, and evidence its
    // owner can rewrite is not evidence.
    await expectLater(
      db.transaction(
        DbScope.tenant(operatorId),
        (tx) => tx.execute(
          Sql.named("UPDATE disruptions SET cause = 'weather' WHERE id = @id"),
          parameters: {'id': TypedValue(Type.uuid, declared.valueOrNull!.id)},
          ignoreRows: true,
        ),
      ),
      throwsA(anything),
    );
  });

  test('another operator cannot declare on this one\'s departure', () async {
    final trip = await sold();

    final refused = await desk.declare(
      operatorId: '22222222-2222-2222-2222-222222222222',
      departureId: trip.departureId,
      kind: DisruptionKind.cancellation,
      cause: DisruptionCause.security,
      actorUserId: dispatcherId,
      now: DateTime.now().toUtc(),
    );

    // The same answer as "no such departure". Telling a stranger which of the
    // two it was confirms the id exists.
    expect(refused.failureOrNull, isA<UnknownDeparture>());
    expect(await fixture.departureStatus(trip.departureId), 'scheduled');
  });

  test(
    'a delay with no new time is refused with the domain\'s own code',
    () async {
      final trip = await sold();

      final refused = await desk.declare(
        operatorId: operatorId,
        departureId: trip.departureId,
        kind: DisruptionKind.delay,
        cause: DisruptionCause.checkpoint,
        actorUserId: dispatcherId,
        now: DateTime.now().toUtc(),
      );

      final failure = refused.failureOrNull! as DeclarationInvalid;
      expect(failure.failure, isA<DelayNeedsARevisedTime>());
      // Nothing was written. A refused declaration that queued messages first
      // would be forty-two people told about a delay that was never declared.
      expect(
        await fixture.outboxCount('disruption.declared', trip.bookingId),
        0,
      );
    },
  );

  test('a coach that arrived yesterday cannot break down today', () async {
    final trip = await sold();
    await fixture.setDepartureStatus(trip.departureId, 'arrived');

    final refused = await declare(trip.departureId);

    expect(refused.failureOrNull, isA<DepartureAlreadyArrived>());
  });

  test('the traveller sees it on their own booking', () async {
    final trip = await sold();
    await declare(
      trip.departureId,
      note: 'moteur',
      location: 'RN1 près de Dolisie',
    );

    final mine = await bookings.forTraveller(trip.travellerId);
    final booking = mine.firstWhere((b) => b.id == trip.bookingId);

    // Read on the public surface, by the traveller, with no tenant at all.
    // During a breakdown this list *is* the information channel, and a
    // passenger who has to phone the agency is the cost being removed.
    expect(
      booking.disruption!.disruption.kind,
      DisruptionKind.breakdownEnRoute,
    );
    expect(booking.disruption!.disruption.location, 'RN1 près de Dolisie');
    expect(booking.involuntaryChange, isTrue);
  });

  test('the operator can account for who declared it', () async {
    final trip = await sold();
    await declare(trip.departureId, note: 'moteur');

    // Keyed to this departure, not to the first declaration in the trail:
    // every test in this file writes one, and the suite shares an operator.
    final trail = await fixture.auditFor(operatorId);
    final entry = trail.singleWhere(
      (r) =>
          r['action'] == 'disruption.declare' &&
          r['subject_id'] == trip.departureId,
    );

    expect(entry['actor_id'].toString(), dispatcherId);
    // The cause, and the dispatcher's own words. "Why" is the question an
    // audit answers and it cannot be reconstructed three weeks later.
    expect(entry['reason'], contains('mechanical'));
    expect(entry['reason'], contains('moteur'));
  });
}
