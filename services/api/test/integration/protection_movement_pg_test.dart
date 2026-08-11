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

/// A passenger moved onto **another company's** coach (`08-disruption.md`
/// §2.2 option ③, §2.3, §5).
///
/// The domain suite proves which agreement covers which road. This file
/// exists for the claims only a database can make — and this is the one
/// operation in the system that crosses a tenant boundary, so they are worth
/// making: that the booking changes hands and its ticket is re-signed under
/// the company now carrying it, that the new seat is taken before the old one
/// is released, that the rebill posts one payable against the other with no
/// commission and no cash, and that an agreement suspended between the ask
/// and the answer authorises nothing.
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
      issuer: await Ed25519TicketIssuer.development(random: Random(53)),
    );
    protection = PostgresProtection(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(59)),
    );
    ocean = PgFixture.operatorId;
    bony = await fixture.secondOperator();
    ourDispatcher = await fixture.traveller('prot-move-us', name: 'Regulation');
    theirDispatcher = await fixture.traveller('prot-move-them', name: 'Bony');
    stationId = await fixture.station('BZV', 'Agence protection');
  });

  setUp(() async => fixture.clearAgreements());

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A live agreement between the two, on the road they both run.
  Future<String> agreed({int discountBps = 1500, int? cap = 40}) async {
    final proposed = await protection.propose(
      operatorId: ocean,
      counterpartyCode: PgFixture.secondOperatorCode,
      corridors: [Corridor('BZV', 'PNR')],
      actorUserId: ourDispatcher,
      rebillDiscountBps: discountBps,
      monthlyCapSeats: cap,
    );
    expect(proposed.refusal, isNull);
    final id = proposed.agreement!.agreement.id;
    final accepted = await protection.decide(
      operatorId: bony,
      agreementId: id,
      decision: 'accept',
      actorUserId: theirDispatcher,
    );
    expect(accepted.refusal, isNull);
    return id;
  }

  /// Our departure, with paid parties on it.
  Future<({String departureId, List<String> bookingIds})> broken({
    List<String> sell = const ['1A'],
    List<String> seats = const ['1A', '1B', '1C'],
  }) async {
    final departureId = await fixture.departure(
      seatLabels: seats,
      fromNow: const Duration(hours: 4),
      fareMinor: 12000,
    );
    final ids = <String>[];
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
      ids.add(booking.id);
    }
    return (departureId: departureId, bookingIds: ids);
  }

  Future<ProtectionRequestView> ask({
    required String departureId,
    required String replacementId,
    String? note,
  }) async {
    final result = await protection.request(
      operatorId: ocean,
      departureId: departureId,
      replacementDepartureId: replacementId,
      actorUserId: ourDispatcher,
      now: DateTime.now().toUtc(),
      note: note,
    );
    expect(result.refusal, isNull, reason: 'the request was refused');
    return result.request!;
  }

  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})> accept(
    String requestId,
  ) => protection.decideRequest(
    operatorId: bony,
    requestId: requestId,
    decision: 'accept',
    actorUserId: theirDispatcher,
    now: DateTime.now().toUtc(),
  );

  group('asking for room', () {
    test('carries what the other company needs to decide', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(
        seatLabels: ['1A', '1B', '1C'],
      );

      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
        note: 'Panne pres de Dolisie',
      );

      expect(request.seatsRequested, 1);
      expect(request.weAsked, isTrue);
      expect(request.state, 'pending');
      // §2.3 asks for a live seat count on the receiving console. A receiving
      // operator deciding blind is one who says no.
      expect(request.seatsFree, 3);
      expect(request.note, 'Panne pres de Dolisie');
      // And what they would be paid, before the decision rather than after:
      // their own 9 000 fare less 15%.
      expect(request.rebill, const Money.xaf(7650));
    });

    test('is refused without a live agreement', () async {
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);

      final result = await protection.request(
        operatorId: ocean,
        departureId: trip.departureId,
        replacementDepartureId: theirs,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal!.code, 'protection.no_agreement');
    });

    test('is refused past the monthly ceiling', () async {
      await agreed(cap: 1);
      final trip = await broken(sell: const ['1A', '1B']);
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);

      // Two people stranded, one seat of ceiling left this month. The ceiling
      // is a commercial term and refusing late — after the seats were taken —
      // would be worse than refusing now.
      final result = await protection.request(
        operatorId: ocean,
        departureId: trip.departureId,
        replacementDepartureId: theirs,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal!.code, 'protection.cap_reached');
    });

    test('is refused onto a coach that leaves before the broken one', () async {
      await agreed();
      final trip = await broken();
      final earlier = await fixture.foreignDeparture(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 1),
      );

      final result = await protection.request(
        operatorId: ocean,
        departureId: trip.departureId,
        replacementDepartureId: earlier,
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(result.refusal!.code, 'rebooking.not_later');
    });

    test('twice on a bad connection is one request, not two', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);

      final first = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );
      final second = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      // The failure mode worth refusing is a receiving console showing the
      // same rescue twice, read as another coachload needing seats.
      expect(second.id, first.id);
      expect(await protection.requestsFor(bony), hasLength(1));
    });

    test('reaches the other company, and nobody else', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);
      await ask(departureId: trip.departureId, replacementId: theirs);

      final inbound = await protection.requestsFor(bony);
      expect(inbound.single.awaitingUs, isTrue);
      expect(inbound.single.weAsked, isFalse);
      expect(inbound.single.counterpartyName, 'Ocean du Nord');

      final stranger = await protection.requestsFor(
        'ffffffff-ffff-ffff-ffff-ffffffffffff',
      );
      expect(stranger, isEmpty);
    });
  });

  group('accepting', () {
    test(
      'moves the booking to the other company, and re-signs its ticket',
      () async {
        await agreed();
        final trip = await broken();
        final theirs = await fixture.foreignDeparture(
          seatLabels: ['1A', '1B', '1C'],
        );
        final request = await ask(
          departureId: trip.departureId,
          replacementId: theirs,
        );

        final decided = await accept(request.id);

        expect(decided.refusal, isNull);
        expect(decided.request!.state, 'applied');
        expect(decided.request!.seatsMoved, 1);

        // The line that makes it protection rather than a rebooking: the
        // passenger is the receiving operator's to carry now.
        final owner = await fixture.ownerOf(trip.bookingIds.single);
        expect(owner.operatorId, bony);
        expect(owner.departureId, theirs);

        // And the ticket is re-signed, because the QR carries the operator as
        // well as the seat (ADR-0007) — one live ticket, not two.
        expect(await fixture.ticketCount(trip.bookingIds.single), 1);
        expect(await fixture.voidedTickets(trip.bookingIds.single), 0);
      },
    );

    test('takes the new seat before releasing the old one', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      await accept(request.id);

      // The seat they left is back on sale, and the one they took is not.
      final ours = await fixture.seatStates(trip.departureId);
      final them = await fixture.seatStates(theirs);
      expect(ours['1A'], 'available');
      expect(them['1A'], 'sold');
    });

    test('settles one payable against the other, and takes nothing', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      final commissionBefore = await fixture.balanceOf(
        LedgerAccount.revenueCommission,
      );
      final oceanBefore = await fixture.balanceOf(
        LedgerAccount.payableOperator(ocean),
      );
      final bonyBefore = await fixture.balanceOf(
        LedgerAccount.payableOperator(bony),
      );
      final bankBefore = await fixture.balanceOf(LedgerAccount.bankOperating);

      await accept(request.id);

      // 9 000 less 15% is 7 650. It moves from one payable to the other and
      // nowhere else.
      expect(
        await fixture.balanceOf(LedgerAccount.payableOperator(ocean)),
        oceanBefore - 7650,
      );
      expect(
        await fixture.balanceOf(LedgerAccount.payableOperator(bony)),
        bonyBefore + 7650,
      );
      // No commission: taxing a rescue would discourage the behaviour the
      // agreement exists to encourage.
      expect(
        await fixture.balanceOf(LedgerAccount.revenueCommission),
        commissionBefore,
      );
      // And no cash moves: it nets into whichever payout run comes next.
      expect(await fixture.balanceOf(LedgerAccount.bankOperating), bankBefore);
      // Whatever it posted, it posted in balance.
      expect(await fixture.unbalancedTxnCount(), 0);
    });

    test('records the movement, so the ceiling counts it', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      await accept(request.id);

      // The number on the card the next time somebody opens the agreement.
      final ours = await protection.agreementsFor(ocean);
      expect(ours.single.seatsUsedThisMonth, 1);
    });

    test('queues one message per passenger, never sends it inline', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      await accept(request.id);

      // ADR-0019: the company name on their ticket has changed, and a
      // roadside rescue never waits on an SMS gateway to say so.
      expect(
        await fixture.outboxCount('booking.protected', trip.bookingIds.single),
        1,
      );
    });

    test('moves everybody who fits, and says who did not', () async {
      await agreed();
      final trip = await broken(sell: const ['1A', '1B']);
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      final decided = await accept(request.id);

      // Partial coverage is a success — "1 / 2" is what a dispatcher acts on.
      expect(decided.request!.seatsMoved, 1);
      expect(
        await fixture.ownerOf(trip.bookingIds.first).then((o) => o.operatorId),
        bony,
      );
      expect(
        await fixture.ownerOf(trip.bookingIds.last).then((o) => o.operatorId),
        ocean,
      );
    });
  });

  group('declining', () {
    test('leaves everybody exactly where they were', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      final decided = await protection.decideRequest(
        operatorId: bony,
        requestId: request.id,
        decision: 'decline',
        actorUserId: theirDispatcher,
        now: DateTime.now().toUtc(),
        reason: 'Complet',
      );

      expect(decided.request!.state, 'declined');
      expect(decided.request!.declineReason, 'Complet');
      final owner = await fixture.ownerOf(trip.bookingIds.single);
      expect(owner.operatorId, ocean);
      expect(owner.departureId, trip.departureId);
    });
  });

  group('who may answer', () {
    test('not the company that asked', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      final decided = await protection.decideRequest(
        operatorId: ocean,
        requestId: request.id,
        decision: 'accept',
        actorUserId: ourDispatcher,
        now: DateTime.now().toUtc(),
      );
      expect(decided.refusal, isA<UnknownRequest>());
      expect(
        await fixture.ownerOf(trip.bookingIds.single).then((o) => o.operatorId),
        ocean,
      );
    });

    test('and not twice', () async {
      await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      await accept(request.id);
      final again = await accept(request.id);
      expect(again.refusal, isA<WrongRequestState>());
    });
  });

  group('the agreement is the authority', () {
    test('suspending it stops a pending request from being applied', () async {
      final agreementId = await agreed();
      final trip = await broken();
      final theirs = await fixture.foreignDeparture(seatLabels: ['1A', '1B']);
      final request = await ask(
        departureId: trip.departureId,
        replacementId: theirs,
      );

      // The consent is re-checked at the moment it is used, not trusted from
      // when the request was written. This is the transaction that would
      // otherwise act on a stale yes.
      await protection.decide(
        operatorId: bony,
        agreementId: agreementId,
        decision: 'suspend',
        actorUserId: theirDispatcher,
      );

      final decided = await accept(request.id);

      expect(decided.refusal!.code, 'protection.no_agreement');
      expect(
        await fixture.ownerOf(trip.bookingIds.single).then((o) => o.operatorId),
        ocean,
      );
    });
  });
}
