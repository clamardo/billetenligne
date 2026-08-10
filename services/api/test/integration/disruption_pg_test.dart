@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/ports/disruption_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_disruptions.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
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
  late PostgresOperatorConsole console;
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
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    desk = PostgresDisruptions(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(41)),
    );
    operatorId = PgFixture.operatorId;
    dispatcherId = await fixture.traveller('irrops-actor', name: 'Régulateur');
    stationId = await fixture.station('BZV', 'Agence IRROPS');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A departure with one paid passenger on it.
  ///
  /// [seats] is the whole coach as far as the seat rows are concerned, and
  /// [seat] is the one that gets sold — a rescue coach has to be tested
  /// against a departure that has somewhere else to put somebody.
  Future<({String departureId, String bookingId, String travellerId})> sold({
    Duration lead = const Duration(hours: 8),
    String seat = '1A',
    List<String> seats = const ['1A', '1B', '1C', '1D', '2A', '2B'],
  }) async {
    final departureId = await fixture.departure(
      seatLabels: seats,
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

  /// A second paid passenger on a departure that already exists.
  Future<String> sell(String departureId, String seat, String name) async {
    final booking = await fixture.reserve(
      db: db,
      bookings: bookings,
      departureId: departureId,
      seatLabel: seat,
      name: name,
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
    return booking.id;
  }

  /// The rescue coach: a real vehicle of this operator's, with its own layout.
  Future<String> rescueCoach(SeatLayout layout) async {
    final saved = await console.saveLayout(
      operatorId: operatorId,
      name: 'Rescue ${DateTime.now().microsecondsSinceEpoch}',
      layout: layout,
    );
    final vehicle = await console.saveVehicle(
      operatorId: operatorId,
      registration: 'RSC${DateTime.now().microsecondsSinceEpoch % 100000}',
      layoutId: saved.id,
    );
    return vehicle!.id;
  }

  group('the rescue coach', () {
    test(
      'a coach of the same shape moves nobody and reissues nothing',
      () async {
        final trip = await sold(seat: '1A');
        final vehicleId = await rescueCoach(SeatLayout.busStandard49());

        final applied = await desk.assignRescueCoach(
          operatorId: operatorId,
          departureId: trip.departureId,
          vehicleId: vehicleId,
          actorUserId: dispatcherId,
          now: DateTime.now().toUtc(),
        );

        final result = applied.valueOrNull!;
        // An operator's spare is usually the same model, and a swap that
        // reissued forty-two tickets for nothing would invalidate every
        // screenshot a passenger has already sent to whoever is meeting them.
        expect(result.remap.movedCount, 0);
        expect(result.ticketsReissued, 0);
        expect(result.passengersTold, 1);
        expect(
          await fixture.seatStates(trip.departureId),
          containsPair('1A', 'sold'),
        );
      },
    );

    test(
      'a different shape moves the passenger and re-signs the ticket',
      () async {
        final trip = await sold(seat: '1D');
        // 1A is sold as well, so the window at the front of the rescue coach
        // is taken and 1D's answer is the *other* window rather than a tie.
        await sell(trip.departureId, '1A', 'Serge N.');
        // 1D is a window on a 2+2 and a middle seat on a 2+3, so this
        // passenger has to move — and their QR carries the seat.
        final vehicleId = await rescueCoach(
          const SeatLayout(
            version: 1,
            mode: TransportMode.bus,
            sections: [
              CabinSection(
                code: 'STD',
                labelKey: 'seat.class.standard',
                rows: 12,
                abreast: '2+3',
              ),
            ],
          ),
        );

        final applied = await desk.assignRescueCoach(
          operatorId: operatorId,
          departureId: trip.departureId,
          vehicleId: vehicleId,
          actorUserId: dispatcherId,
          now: DateTime.now().toUtc(),
        );

        final result = applied.valueOrNull!;
        expect(result.remap.destinationOf('1D'), '1E');
        expect(result.ticketsReissued, 1);

        // One live ticket, on the seat the manifest now says. Two would be two
        // people boarding on one fare.
        expect(await fixture.ticketCount(trip.bookingId), 1);
        expect(await fixture.ticketSeats(trip.bookingId), ['1E']);
        expect(await fixture.bookingSeatLabels(trip.bookingId), ['1E']);
        expect(
          await fixture.seatStates(trip.departureId),
          containsPair('1E', 'sold'),
        );
      },
    );

    test(
      'a coach that is too small is refused, with the number short',
      () async {
        final trip = await sold(seat: '1A');
        final vehicleId = await rescueCoach(
          const SeatLayout(
            version: 1,
            mode: TransportMode.bus,
            sections: [
              CabinSection(
                code: 'STD',
                labelKey: 'seat.class.standard',
                rows: 1,
                abreast: '1',
                startRow: 40,
              ),
            ],
          ),
        );

        // One seat, and it is 40A — so the passenger in 1A has somewhere to go
        // and the refusal has to come from the count rather than the labels.
        await sell(trip.departureId, '1B', 'Serge N.');

        final refused = await desk.assignRescueCoach(
          operatorId: operatorId,
          departureId: trip.departureId,
          vehicleId: vehicleId,
          actorUserId: dispatcherId,
          now: DateTime.now().toUtc(),
        );

        final failure = refused.failureOrNull! as CannotSeatEverybody;
        expect(failure.short, 1);
        // Nothing happened. A half-applied swap is a manifest that disagrees
        // with the tickets, at a roadside, in front of the people it disagrees
        // about.
        expect(
          await fixture.seatStates(trip.departureId),
          containsPair('1A', 'sold'),
        );
      },
    );

    test('somebody else\'s coach is not a rescue', () async {
      final trip = await sold(seat: '1A');

      final refused = await desk.assignRescueCoach(
        operatorId: operatorId,
        departureId: trip.departureId,
        vehicleId: '00000000-0000-0000-0000-0000000000ff',
        actorUserId: dispatcherId,
        now: DateTime.now().toUtc(),
      );

      expect(refused.failureOrNull, isA<UnusableVehicle>());
    });

    test('the swap supersedes the breakdown that caused it', () async {
      final trip = await sold(seat: '1A');
      await declare(trip.departureId);
      final vehicleId = await rescueCoach(SeatLayout.busStandard49());

      await desk.assignRescueCoach(
        operatorId: operatorId,
        departureId: trip.departureId,
        vehicleId: vehicleId,
        actorUserId: dispatcherId,
        now: DateTime.now().toUtc(),
      );

      // "What is happening to my coach right now?" answers with the
      // resolution, not with the problem.
      final open = await desk.openFor(
        operatorId: operatorId,
        from: DateTime.now().toUtc().subtract(const Duration(days: 1)),
        to: DateTime.now().toUtc().add(const Duration(days: 2)),
      );
      expect(
        open[trip.departureId]!.disruption.kind,
        DisruptionKind.equipmentSwap,
      );

      // And everybody is told again, on the event that carries their seat.
      expect(
        await fixture.outboxCount('disruption.resolved', trip.bookingId),
        1,
      );
    });

    test('a hold with nothing behind it is released, not moved', () async {
      final trip = await sold(seat: '1A');
      final holder = await fixture.traveller(
        'holder-${DateTime.now().microsecondsSinceEpoch % 100000}',
        name: 'Passant',
      );
      await HoldSeats(inventory: PostgresSeatInventory(db))(
        departureId: trip.departureId,
        seatLabels: ['2A'],
        userId: holder,
        idempotencyKey: 'rescue-${DateTime.now().microsecondsSinceEpoch}',
      );

      final vehicleId = await rescueCoach(SeatLayout.busStandard49());
      final applied = await desk.assignRescueCoach(
        operatorId: operatorId,
        departureId: trip.departureId,
        vehicleId: vehicleId,
        actorUserId: dispatcherId,
        now: DateTime.now().toUtc(),
      );

      // Somebody mid-checkout on a coach that has just been swapped loses
      // their seat and chooses again. Moving a held seat under them silently
      // is worse than telling them.
      expect(applied.valueOrNull!.holdsReleased, 1);
      expect(
        await fixture.seatStates(trip.departureId),
        containsPair('2A', 'available'),
      );
    });
  });

  group('the rebooking wave', () {
    /// The 14:00 on the same road, with room for [seats] people.
    Future<String> replacement({
      List<String> seats = const ['1A', '1B', '1C'],
      Duration lead = const Duration(hours: 14),
      String status = 'scheduled',
      String? onRoute,
    }) => fixture.departure(
      seatLabels: seats,
      fromNow: lead,
      fareMinor: 9000,
      status: status,
      onRoute: onRoute,
    );

    Future<Result<RebookingApplied, DeclarationRefusal>> rebook(
      String from,
      String onto,
    ) => desk.rebookOnto(
      operatorId: operatorId,
      departureId: from,
      replacementDepartureId: onto,
      actorUserId: dispatcherId,
      now: DateTime.now().toUtc(),
    );

    test('a passenger moves, and the ticket moves with them', () async {
      final trip = await sold(seat: '1A');
      final later = await replacement();

      final applied = await rebook(trip.departureId, later);
      final result = applied.valueOrNull!;

      expect(result.passengersMoved, 1);
      expect(result.passengersLeft, 0);
      expect(result.plan.coversEverybody, isTrue);

      // The booking is on the other coach now, on a seat that coach has.
      expect(await fixture.departureOf(trip.bookingId), later);
      expect(await fixture.bookingSeatLabels(trip.bookingId), ['1A']);
      expect(await fixture.seatStates(later), containsPair('1A', 'sold'));
      // And the seat they left is back on sale, because the broken coach may
      // yet run — an equipment swap on it would find the seat free.
      expect(
        await fixture.seatStates(trip.departureId),
        containsPair('1A', 'available'),
      );
    });

    test('the ticket is re-signed, because the trip changed', () async {
      final trip = await sold(seat: '1A');
      final later = await replacement();

      await rebook(trip.departureId, later);

      // One live ticket. The departure is inside the signed payload, so a
      // ticket still naming the broken coach scans as the wrong trip.
      expect(await fixture.ticketCount(trip.bookingId), 1);
      expect(await fixture.ticketSeats(trip.bookingId), ['1A']);
    });

    test('everybody moved is exempt from fees, permanently', () async {
      final trip = await sold(seat: '1A');
      final later = await replacement();

      await rebook(trip.departureId, later);

      // The flag that makes the rest of ADR-0016 true: no fee, and no fare
      // difference even when the replacement is dearer.
      expect(await fixture.involuntaryBookings(later), 1);
    });

    test(
      'a replacement with no room for everybody covers who it can',
      () async {
        final trip = await sold(seat: '1A');
        await sell(trip.departureId, '1B', 'Serge N.');
        await sell(trip.departureId, '1C', 'Marie K.');
        final later = await replacement(seats: const ['1A']);

        final result = (await rebook(trip.departureId, later)).valueOrNull!;

        // "1 / 3" is the honest answer, and the one a dispatcher combines with
        // a rescue coach. Refusing anything short of everybody would mean the
        // tool only works on the days it is not needed.
        expect(result.passengersMoved, 1);
        expect(result.passengersLeft, 2);
        expect(result.plan.coversEverybody, isFalse);
        // Whoever booked first. The only ordering that can be said out loud to
        // the two who were left.
        expect(result.moved.single.bookingId, trip.bookingId);
      },
    );

    test('a replacement that can take nobody is refused', () async {
      final trip = await sold(seat: '1A');
      final full = await replacement(seats: const ['1A']);
      await sell(full, '1A', 'Déjà là');

      final refused = await rebook(trip.departureId, full);

      // Not a wave that moved nobody: "0 / 42" dressed up as a success is how
      // a dispatcher walks away believing the problem is handled.
      final failure = refused.failureOrNull! as ReplacementRefused;
      expect(failure.failure, isA<NobodyFits>());
      expect(await fixture.departureOf(trip.bookingId), trip.departureId);
    });

    test('a different road is not a re-accommodation', () async {
      final trip = await sold(seat: '1A');
      final elsewhere = await replacement(
        onRoute: await fixture.route(code: 'BZV-OYO'),
      );

      final refused = await rebook(trip.departureId, elsewhere);
      expect(
        (refused.failureOrNull! as ReplacementRefused).failure,
        isA<DifferentRoute>(),
      );
    });

    test('a departure cannot rescue itself', () async {
      final trip = await sold(seat: '1A');

      final refused = await rebook(trip.departureId, trip.departureId);
      expect(
        (refused.failureOrNull! as ReplacementRefused).failure,
        isA<SameDeparture>(),
      );
    });

    test('an earlier departure cannot be reached', () async {
      final trip = await sold(seat: '1A', lead: const Duration(hours: 10));
      final earlier = await replacement(lead: const Duration(hours: 4));

      final refused = await rebook(trip.departureId, earlier);
      expect(
        (refused.failureOrNull! as ReplacementRefused).failure,
        isA<ReplacementNotLater>(),
      );
    });

    test('a cancelled replacement is not a replacement', () async {
      final trip = await sold(seat: '1A');
      final later = await replacement();
      await fixture.setDepartureStatus(later, 'cancelled');

      final refused = await rebook(trip.departureId, later);
      expect(
        (refused.failureOrNull! as ReplacementRefused).failure,
        isA<ReplacementNotSellable>(),
      );
    });

    test('a coach nobody is on has nobody to move', () async {
      final empty = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 6),
      );
      final later = await replacement();

      final refused = await rebook(empty, later);
      expect(
        (refused.failureOrNull! as ReplacementRefused).failure,
        isA<NothingToMove>(),
      );
    });

    test('somebody else\'s departure is not found', () async {
      final trip = await sold(seat: '1A');

      final refused = await desk.rebookOnto(
        operatorId: operatorId,
        departureId: trip.departureId,
        replacementDepartureId: '00000000-0000-0000-0000-0000000000ff',
        actorUserId: dispatcherId,
        now: DateTime.now().toUtc(),
      );

      expect(refused.failureOrNull, isA<UnknownDeparture>());
    });

    test('everybody moved is told, once', () async {
      final trip = await sold(seat: '1A');
      final later = await replacement();

      await rebook(trip.departureId, later);

      // Through the outbox, never inline with the dispatcher's request
      // (ADR-0019 rule 1) — and keyed per departure-and-booking, so a second
      // wave over the same pair does not send twice.
      expect(await fixture.outboxCount('booking.rebooked', trip.bookingId), 1);
    });

    test('who was moved where is written down', () async {
      final trip = await sold(seat: '1A');
      final later = await replacement();

      await rebook(trip.departureId, later);

      // §2.4: the operator's own evidence in a later dispute. Not derivable
      // from the bookings afterwards — they only show where people ended up.
      final entry = (await fixture.auditFor(operatorId)).singleWhere(
        (e) =>
            e['action'] == 'disruption.rebook' &&
            e['subject_id'] == trip.departureId,
      );
      expect(entry['actor_id'].toString(), dispatcherId);
      expect(entry['after_state']['passengersMoved'], 1);
      expect(entry['after_state']['replacementDepartureId'], later);
    });
  });

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
