@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_protection.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Open protection — the call put out to the whole road (`08-disruption.md`
/// §5, last paragraph).
///
/// The agreement suite proves what two companies who already know each other
/// can do. This file is about the company that knows nobody, which on day one
/// is every company: a coach fails, there is no agreement with anyone, and
/// the alternative to this is a refund.
///
/// The claims only a database can make, and each of them is a way this could
/// go wrong on a real morning:
///
///   * **who was invited** is computed from data — opted in, selling, on the
///     road — so an operator who never said yes sees nothing, and one blocked
///     on their own paperwork is not sent anybody's passengers;
///   * **first to accept wins**, and the loser is told rather than left
///     believing they have taken the passengers on;
///   * an answer that could not move anybody **leaves the call open**, so a
///     rescuer whose seats sold underneath them does not consume somebody
///     else's last chance;
///   * and the movement is the same movement, with the same ledger posting,
///     reached by a call instead of by an agreement.
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
  late PostgresProtection protection;
  late String ocean;
  late String bony;
  late String ourDispatcher;
  late String theirDispatcher;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(71)),
    );
    protection = PostgresProtection(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(73)),
    );
    ocean = PgFixture.operatorId;
    bony = await fixture.secondOperator();
    ourDispatcher = await fixture.traveller('open-prot-us', name: 'Regulation');
    theirDispatcher = await fixture.traveller('open-prot-them', name: 'Bony');
    stationId = await fixture.station('BZV', 'Agence appels');
  });

  setUp(() async => fixture.clearAgreements());

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// Our departure, with paid passengers on it.
  Future<String> broken({List<String> sell = const ['1A']}) async {
    final departureId = await fixture.departure(
      seatLabels: const ['1A', '1B', '1C'],
      fromNow: const Duration(hours: 4),
      fareMinor: 12000,
    );
    for (final seat in sell) {
      final booking = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: seat,
        name: 'Aline M.',
      );
      await bookings.captureCash(
        bookingId: booking.id,
        operatorId: ocean,
        stationId: stationId,
        soldByUserId: ourDispatcher,
        posting: Postings.cashSale(
          operatorId: ocean,
          stationId: stationId,
          fare: booking.fare,
          serviceFee: booking.serviceFee,
        ).valueOrNull!,
      );
    }
    return departureId;
  }

  Future<OpenCallView> call(String departureId, {String? note}) async {
    final result = await protection.openCall(
      operatorId: ocean,
      departureId: departureId,
      actorUserId: ourDispatcher,
      now: DateTime.now().toUtc(),
      note: note,
    );
    expect(result.refusal, isNull, reason: 'the call was refused');
    return result.call!;
  }

  group('putting the call out', () {
    test('asks for exactly the people who are on the coach', () async {
      final departureId = await broken(sell: ['1A', '1B']);
      final live = await call(departureId, note: 'Panne pres de Dolisie');

      expect(live.seatsRequested, 2);
      expect(live.weOpened, isTrue);
      expect(live.state, 'open');
      expect(live.originCity, 'BZV');
      expect(live.destinationCity, 'PNR');
      expect(live.note, 'Panne pres de Dolisie');
      // The sender's own fare, stated on the call. An operator deciding in
      // ninety seconds needs the number in front of them.
      expect(live.rebillPerSeat, const Money.xaf(12000));
    });

    test('an empty coach is not a call', () async {
      // Broadcasting nobody to every operator on the road is how a useful
      // channel becomes one nobody reads.
      final departureId = await broken(sell: const []);
      final result = await protection.openCall(
        operatorId: ocean,
        departureId: departureId,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal, isA<NobodyCouldBeMoved>());
    });

    test('tapping twice does not put out two calls', () async {
      final departureId = await broken();
      await call(departureId);

      final again = await protection.openCall(
        operatorId: ocean,
        departureId: departureId,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      // Read on every console in the country as a second forty-two people.
      expect(again.refusal, isA<CallAlreadyClosed>());
    });

    test('a coach that is not ours cannot be called for', () async {
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);
      final result = await protection.openCall(
        operatorId: ocean,
        departureId: theirs,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal, isA<UnknownCall>());
    });

    test('withdrawing takes it off every console', () async {
      final live = await call(await broken());
      final gone = await protection.withdrawCall(
        operatorId: ocean,
        callId: live.id,
        actorUserId: ourDispatcher,
      );

      expect(gone.refusal, isNull);
      expect(gone.call!.state, 'withdrawn');

      // And the other company stops seeing it, which is the point of
      // withdrawing rather than ignoring.
      await fixture.receiveOpenCalls(bony);
      final theirs = await protection.openCalls(bony);
      expect(theirs.calls.where((c) => c.id == live.id), isEmpty);
    });
  });

  group('who was invited', () {
    test('an operator who never opted in sees nothing', () async {
      final live = await call(await broken());
      final theirs = await protection.openCalls(bony);

      expect(theirs.receiving, isFalse);
      expect(theirs.calls.where((c) => c.id == live.id), isEmpty);
    });

    test('opting in puts the road in their inbox', () async {
      final live = await call(await broken(sell: ['1A', '1B']));

      final now = await protection.receiveOpenCalls(
        operatorId: bony,
        receiving: true,
        actorUserId: theirDispatcher,
      );
      expect(now, isTrue);

      final theirs = await protection.openCalls(bony);
      expect(theirs.receiving, isTrue);

      final seen = theirs.calls.singleWhere((c) => c.id == live.id);
      // Not ours to chase — ours to answer — and it names who is asking,
      // because that is part of the decision.
      expect(seen.weOpened, isFalse);
      expect(seen.sendingOperatorName, 'Ocean du Nord');
      expect(seen.seatsRequested, 2);
      // The counterparty's own departure time, which lives in a table this
      // reader has no grant on. Without the definer function this is null and
      // the card cannot say when the coach was due.
      expect(seen.departsAt, isNotNull);
    });

    test('a company blocked on its own paperwork is sent nobody', () async {
      final live = await call(await broken());
      await fixture.receiveOpenCalls(bony);
      await fixture.blockSales(bony, doc: 'fleet_insurance');

      final theirs = await protection.openCalls(bony);
      // Still in the channel — they said yes and that stands — but not a
      // company we route passengers to today.
      expect(theirs.receiving, isTrue);
      expect(theirs.calls.where((c) => c.id == live.id), isEmpty);

      await fixture.unblockSales(bony);
    });

    test('leaving the channel empties the inbox again', () async {
      final live = await call(await broken());
      await fixture.receiveOpenCalls(bony);
      expect(
        (await protection.openCalls(bony)).calls.map((c) => c.id),
        contains(live.id),
      );

      await protection.receiveOpenCalls(
        operatorId: bony,
        receiving: false,
        actorUserId: theirDispatcher,
      );
      final after = await protection.openCalls(bony);
      expect(after.receiving, isFalse);
      expect(after.calls.where((c) => c.id == live.id), isEmpty);
    });
  });

  group('answering', () {
    test('moves the passengers and settles the rebill', () async {
      final departureId = await broken(sell: ['1A', '1B']);
      final live = await call(departureId);
      await fixture.receiveOpenCalls(bony);
      final theirs = await fixture.foreignDeparture(
        seatLabels: ['1A', '1B', '1C'],
      );

      final answered = await protection.answerCall(
        operatorId: bony,
        callId: live.id,
        replacementDepartureId: theirs,
        actorUserId: theirDispatcher,
        now: DateTime.now().toUtc(),
      );

      expect(answered.refusal, isNull);
      final request = answered.request!;
      expect(request.state, 'applied');
      expect(request.seatsMoved, 2);
      // The authority is the call, and there is no agreement anywhere in it.
      expect(request.callId, live.id);
      expect(request.agreementId, isNull);

      // The call is closed by the same transaction that moved them.
      final row = await fixture.callRow(live.id);
      expect(row!['state'], 'answered');
      expect(row['answered_by_operator'], bony);

      // The movement is the same movement: a payable one way and the other,
      // no commission and no cash. Rebilled at the *rescuer's* fare — the
      // seat they gave up — with no discount, because nothing was negotiated.
      final movement = await fixture.protectionMovement(request.id);
      expect(movement, isNotNull);
      expect(movement!['seats'], 2);
      expect(movement['call_id'], live.id);
      expect(movement['agreement_id'], isNull);
      expect(movement['rebill_minor'], 2 * 9000);
    });

    test('first to accept wins, and the loser is told', () async {
      final live = await call(await broken());
      await fixture.receiveOpenCalls(bony);
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final alsoTheirs = await fixture.foreignDeparture(
        seatLabels: ['2A', '2B'],
      );

      final first = await protection.answerCall(
        operatorId: bony,
        callId: live.id,
        replacementDepartureId: theirs,
        actorUserId: theirDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(first.refusal, isNull);

      // The second dispatcher was looking at the same `open` a moment ago.
      // They are told, rather than left believing they have taken forty-two
      // people on.
      final second = await protection.answerCall(
        operatorId: bony,
        callId: live.id,
        replacementDepartureId: alsoTheirs,
        actorUserId: theirDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(second.refusal, isA<CallAlreadyClosed>());
      expect(second.request, isNull);

      // And nobody was moved twice.
      expect(await fixture.seatStateOn(alsoTheirs, '2A'), 'available');
    });

    test(
      'an answer that could not move anybody leaves the call open',
      () async {
        final live = await call(await broken());
        await fixture.receiveOpenCalls(bony);
        // A coach with no room left. The rescuer sold the seats while the
        // call sat on their screen, which is exactly what they should have
        // been doing.
        final full = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
        await fixture.fillDeparture(full, heldBy: bony);

        final result = await protection.answerCall(
          operatorId: bony,
          callId: live.id,
          replacementDepartureId: full,
          actorUserId: theirDispatcher,
          now: DateTime.now().toUtc(),
        );
        expect(result.refusal, isA<NobodyCouldBeMoved>());

        // Still open, for somebody else to answer. A failed answer that
        // consumed the call would strand the passengers on a technicality.
        final row = await fixture.callRow(live.id);
        expect(row!['state'], 'open');
        expect(row['closed_at'], isNull);
      },
    );

    test('a call cannot be answered with somebody else\'s coach', () async {
      final live = await call(await broken());
      await fixture.receiveOpenCalls(bony);
      // Ours, not theirs. Naming a departure we do not own is not an answer.
      final ours = await fixture.departure(
        seatLabels: const ['3A', '3B'],
        fromNow: const Duration(hours: 8),
      );

      final result = await protection.answerCall(
        operatorId: bony,
        callId: live.id,
        replacementDepartureId: ours,
        actorUserId: theirDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal, isA<UnknownCall>());
      expect((await fixture.callRow(live.id))!['state'], 'open');
    });

    test('we cannot answer our own call for help', () async {
      final live = await call(await broken());
      final ours = await fixture.departure(
        seatLabels: const ['4A', '4B'],
        fromNow: const Duration(hours: 8),
      );

      final result = await protection.answerCall(
        operatorId: ocean,
        callId: live.id,
        replacementDepartureId: ours,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal, isA<UnknownCall>());
    });

    test('an expired call is not answerable', () async {
      final live = await call(await broken());
      await fixture.receiveOpenCalls(bony);
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);
      await fixture.expireCall(live.id);

      final result = await protection.answerCall(
        operatorId: bony,
        callId: live.id,
        replacementDepartureId: theirs,
        actorUserId: theirDispatcher,
        // The clock the caller carries, not the row's — and it is past the
        // window either way.
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal, isA<CallAlreadyClosed>());
    });
  });

  group('the trail', () {
    test('every step is written under the operator who took it', () async {
      final live = await call(await broken());
      await protection.receiveOpenCalls(
        operatorId: bony,
        receiving: true,
        actorUserId: theirDispatcher,
      );

      final ourTrail = await fixture.auditFor(ocean);
      expect(
        ourTrail.map((r) => r['action']),
        contains('protection.call_opened'),
      );

      final theirTrail = await fixture.auditFor(bony);
      expect(
        theirTrail.map((r) => r['action']),
        contains('protection.open_in'),
      );

      await protection.withdrawCall(
        operatorId: ocean,
        callId: live.id,
        actorUserId: ourDispatcher,
      );
      expect(
        (await fixture.auditFor(ocean)).map((r) => r['action']),
        contains('protection.call_withdrawn'),
      );
    });
  });
}
