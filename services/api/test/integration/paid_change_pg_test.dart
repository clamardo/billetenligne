@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/adapters/fake_payment_gateway.dart';
import 'package:bel_api/src/application/pay_for_booking.dart';
import 'package:bel_api/src/application/ports/payment_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_directory.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_payment_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_reschedules.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Collecting the fare difference in the app (`01-feature-spec.md` §8.1).
///
/// The suite that proves the promise and the movement are two things. A
/// change order holds seats and moves nothing; the capture moves the booking
/// and nothing else may. Everything here is against a real database because
/// every claim worth making is about a transaction: seats held rather than
/// sold, one order per booking, a move that happens exactly once.
///
/// The clock is the real one, as in the reschedule suite: the candidate query
/// filters on Postgres's `now()`.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  const railId = 'cg.fake_money';
  const payer = '242061234567';

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorConsole console;
  late PostgresBookingStore bookings;
  late PostgresReschedules desk;
  late PostgresPaymentStore payments;
  late FakePaymentGateway rail;
  late PayForBooking pay;
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
      issuer: await Ed25519TicketIssuer.development(random: Random(61)),
    );
    desk = PostgresReschedules(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(61)),
    );
    payments = PostgresPaymentStore(db);
    rail = FakePaymentGateway(railId: railId);
    pay = PayForBooking(
      payments: payments,
      bookings: bookings,
      operators: PostgresOperatorDirectory(db),
      gateways: {railId: rail},
      reschedules: desk,
    );
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('paid-change-actor', name: 'Vendeur');
    stationId = await fixture.station('BZV', 'Agence Différences');
    now = DateTime.now().toUtc();
    await fixture.collectionAccount(railId: railId, msisdn: '242060000001');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  setUp(() => fixture.agreeCommission(500));

  var seq = 0;
  String key() => 'chg-${++seq}-${DateTime.now().microsecondsSinceEpoch}';

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

  /// A paid booking, and a dearer departure on the same route to move to.
  Future<({String ref, String id, String from, String userId, String target})>
  sold({
    int targetFareMinor = 10500,
    List<String> targetSeats = const ['5A', '5B'],
    Duration targetLead = const Duration(hours: 40),
  }) async {
    final departureId = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(hours: 30),
      fareMinor: 9000,
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
    );

    return (
      ref: booking.ref.value,
      id: booking.id,
      from: departureId,
      userId: await fixture.purchaserOf(booking.id),
      target: target,
    );
  }

  group('the promise', () {
    test('an order holds the seats and moves nothing', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      final result = await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      final order = result!.order!;
      expect(order.isAwaitingPayment, isTrue);
      expect(order.owed, const Money.xaf(1500));
      expect(order.seatLabels, ['5A']);

      // Held, not sold: nobody has paid for that seat yet.
      expect(await fixture.seatStateOn(trip.target, '5A'), 'held');
      // And the booking has not moved an inch.
      expect(await fixture.departureOf(trip.id), trip.from);
      expect(await fixture.seatStateOn(trip.from, '1A'), 'sold');
      expect(await fixture.ticketSeats(trip.id), ['1A']);
    });

    test('what was quoted is what is stored', () async {
      // Six hours out: inside the fee band, so both halves are non-zero and
      // a row that stored only the total would be caught here.
      await sellUnder(const ChangePolicy(feeBps: 1000));
      final trip = await sold(targetLead: const Duration(hours: 20));

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      final row = (await fixture.changeOrder(order.id))!;
      expect(row['fee_minor'], order.fee.minor);
      expect(row['difference_minor'], order.fareDifference.minor);
      expect(row['owed_minor'], order.owed.minor);
      expect(row['state'], 'awaiting_payment');
      expect(row['applied_at'], isNull);
    });

    test('a difference that evaporated is applied at once', () async {
      await sellUnder(ChangePolicy.standard);
      // Same fare, free window: nothing is owed, so there is no promise to
      // keep — only a movement that happens.
      final trip = await sold(targetFareMinor: 9000);

      final result = await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      expect(result!.order!.isApplied, isTrue);
      expect(result.order!.applied!.seatLabels, ['5A']);
      expect(await fixture.departureOf(trip.id), trip.target);
      expect(await fixture.seatStateOn(trip.target, '5A'), 'sold');
      expect(await fixture.seatStateOn(trip.from, '1A'), 'available');
    });

    test('a stranger gets the same answer as a wrong reference', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final stranger = await fixture.traveller('paid-change-stranger');

      expect(
        await desk.reserveChange(
          bookingRef: trip.ref,
          userId: stranger,
          toDepartureId: trip.target,
          now: now,
        ),
        isNull,
      );
      expect(
        await desk.reserveChange(
          bookingRef: 'BEL-ZZZZZZ',
          userId: trip.userId,
          toDepartureId: trip.target,
          now: now,
        ),
        isNull,
      );
    });

    test('changing their mind releases the first order', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(targetSeats: const ['5A', '5B']);
      final second = await fixture.departure(
        seatLabels: const ['6A'],
        fromNow: const Duration(hours: 44),
        fareMinor: 10500,
      );

      final first = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      final swapped = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: second,
        now: now,
      ))!.order!;

      // Nobody answered a prompt for the first one, so its seats go straight
      // back on sale rather than sitting out the window.
      expect(swapped.toDepartureId, second);
      expect((await fixture.changeOrder(first.id))!['state'], 'cancelled');
      expect(await fixture.seatStateOn(trip.target, '5A'), 'available');
      expect(await fixture.seatStateOn(second, '6A'), 'held');
    });

    test('a prompt in flight refuses a second order', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final second = await fixture.departure(
        seatLabels: const ['6A'],
        fromNow: const Duration(hours: 44),
        fareMinor: 10500,
      );

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      await pay.start(
        bookingId: trip.id,
        userId: trip.userId,
        railId: railId,
        payerMsisdn: payer,
        accountMsisdn: payer,
        idempotencyKey: key(),
        changeId: order.id,
      );

      final refused = await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: second,
        now: now,
      );

      // Releasing those seats could strand money that is about to land.
      expect(refused!.refusal, isA<ChangePaymentInFlight>());
      expect(await fixture.seatStateOn(trip.target, '5A'), 'held');
      expect(await fixture.seatStateOn(second, '6A'), 'available');
    });
  });

  group('changing their mind', () {
    test('the order is on the screen they come back to', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );

      // Without this the seats are held for a quarter of an hour with
      // nothing anywhere saying so, and the only ways out were to pay or to
      // wait.
      expect(screen!.pending!.id, order.id);
      expect(screen.pending!.owed, order.owed);
      expect(screen.pending!.toDepartureId, trip.target);
    });

    test('cancelling puts the seats back on sale at once', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;
      expect(await fixture.seatStateOn(trip.target, '5A'), 'held');

      final cancelled = await desk.cancelChange(
        bookingRef: trip.ref,
        userId: trip.userId,
      );

      expect(cancelled!.released, isTrue);
      expect(cancelled.refusal, isNull);
      expect(await fixture.seatStateOn(trip.target, '5A'), 'available');
      expect((await fixture.changeOrder(order.id))!['state'], 'cancelled');
      // The booking never moved, which is the whole point of an order.
      expect(await fixture.departureOf(trip.id), trip.from);
    });

    test('the screen forgets it afterwards', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );
      await desk.cancelChange(bookingRef: trip.ref, userId: trip.userId);

      final screen = await desk.options(
        bookingRef: trip.ref,
        userId: trip.userId,
        now: now,
      );
      expect(screen!.pending, isNull);
    });

    test('cancelling twice is cancelling once', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );
      await desk.cancelChange(bookingRef: trip.ref, userId: trip.userId);

      final again = await desk.cancelChange(
        bookingRef: trip.ref,
        userId: trip.userId,
      );

      // Nothing waiting, and no error: the sweeper may have got there first,
      // or they tapped twice on a connection that dropped.
      expect(again!.released, isFalse);
      expect(again.refusal, isNull);
    });

    test('a prompt in flight refuses the cancellation', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      await pay.start(
        bookingId: trip.id,
        userId: trip.userId,
        railId: railId,
        payerMsisdn: payer,
        accountMsisdn: payer,
        idempotencyKey: key(),
        changeId: order.id,
      );

      final refused = await desk.cancelChange(
        bookingRef: trip.ref,
        userId: trip.userId,
      );

      // The same refusal as reserving a second order, and for the same
      // reason: money is about to land on these seats.
      expect(refused!.released, isFalse);
      expect(refused.refusal, isA<ChangePaymentInFlight>());
      expect(await fixture.seatStateOn(trip.target, '5A'), 'held');
    });

    test('somebody else-s booking is not theirs to cancel', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      );

      final stranger = await fixture.traveller('change-stranger');

      // Null, exactly as a reference that was never issued answers — this is
      // not a way to release other people's seats or to learn which
      // references exist.
      expect(
        await desk.cancelChange(bookingRef: trip.ref, userId: stranger),
        isNull,
      );
      expect(await fixture.seatStateOn(trip.target, '5A'), 'held');
    });
  });

  group('the money', () {
    test('the prompt is for the order, at the order-s price', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      final started = await pay.start(
        bookingId: trip.id,
        userId: trip.userId,
        railId: railId,
        payerMsisdn: payer,
        accountMsisdn: payer,
        idempotencyKey: key(),
        changeId: order.id,
      );

      final intent = started.valueOrNull!;
      // The difference, not the fare: the client named which debt, and the
      // server read how much from the order's own row.
      expect(intent.amount, const Money.xaf(1500));
      expect(intent.changeId, order.id);
      expect(intent.bookingId, trip.id);
    });

    test('a stranger cannot open a prompt against somebody-s order', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final stranger = await fixture.traveller('paid-change-thief');

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      expect(
        await payments.openForChange(
          changeId: order.id,
          userId: stranger,
          railId: railId,
          payerMsisdn: payer,
          payerIsAccountHolder: false,
          idempotencyKey: key(),
          window: const Duration(minutes: 10),
        ),
        isNull,
      );
    });

    test('a lapsed order takes no PIN', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;
      await fixture.lapseChangeOrder(order.id);

      // The seats may already be back on sale; money arriving for them would
      // be money for a seat somebody else is sitting in.
      expect(
        await payments.openForChange(
          changeId: order.id,
          userId: trip.userId,
          railId: railId,
          payerMsisdn: payer,
          payerIsAccountHolder: true,
          idempotencyKey: key(),
          window: const Duration(minutes: 10),
        ),
        isNull,
      );
    });
  });

  group('the movement', () {
    Future<({String changeId, String intentId, String bookingId})> paid({
      int targetFareMinor = 10500,
    }) async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold(targetFareMinor: targetFareMinor);

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      final started = await pay.start(
        bookingId: trip.id,
        userId: trip.userId,
        railId: railId,
        payerMsisdn: payer,
        accountMsisdn: payer,
        idempotencyKey: key(),
        changeId: order.id,
      );

      return (
        changeId: order.id,
        intentId: started.valueOrNull!.id,
        bookingId: trip.id,
      );
    }

    test('the capture moves the booking and re-signs the ticket', () async {
      await sellUnder(ChangePolicy.standard);
      final trip = await sold();
      final before = await fixture.ledgerRowsFor(trip.id);

      final order = (await desk.reserveChange(
        bookingRef: trip.ref,
        userId: trip.userId,
        toDepartureId: trip.target,
        now: now,
      ))!.order!;

      final started = await pay.start(
        bookingId: trip.id,
        userId: trip.userId,
        railId: railId,
        payerMsisdn: payer,
        accountMsisdn: payer,
        idempotencyKey: key(),
        changeId: order.id,
      );

      // The rail answers captured on the poll, which is what the worker does
      // a few seconds after the prompt goes out.
      rail.statusScript.add(
        const PaymentOutcome(
          state: PaymentState.captured,
          raw: {'fake': 'captured'},
        ),
      );
      final settled = await pay.reconcile(
        intentId: started.valueOrNull!.id,
        railId: railId,
      );
      expect(settled!.state, PaymentState.captured);

      expect(await fixture.departureOf(trip.id), trip.target);
      expect(await fixture.seatStateOn(trip.target, '5A'), 'sold');
      expect(await fixture.seatStateOn(trip.from, '1A'), 'available');
      // The QR carries the seat and the departure, so a ticket left alone
      // would admit somebody to a seat the manifest has given away.
      expect(await fixture.ticketSeats(trip.id), ['5A']);
      expect((await fixture.changeOrder(order.id))!['state'], 'applied');
      // The difference is in the ledger, in the same transaction as the move.
      expect(await fixture.ledgerRowsFor(trip.id), greaterThan(before));
    });

    test('a duplicate capture moves one booking once', () async {
      final settled = await paid();

      final first = await desk.applyPaidChange(
        changeId: settled.changeId,
        intentId: settled.intentId,
        posting: Postings.railCapture(
          operatorId: operatorId,
          rail: railId,
          fare: const Money.xaf(1500),
          serviceFee: const Money.xaf(0),
          commission: const Money.xaf(75),
        ).valueOrNull!,
      );
      final rows = await fixture.ledgerRowsFor(settled.bookingId);

      // A callback and a poll landing together is a normal event on these
      // rails, and the answer is the one it already gave.
      final again = await desk.applyPaidChange(
        changeId: settled.changeId,
        intentId: settled.intentId,
        posting: Postings.railCapture(
          operatorId: operatorId,
          rail: railId,
          fare: const Money.xaf(1500),
          serviceFee: const Money.xaf(0),
          commission: const Money.xaf(75),
        ).valueOrNull!,
      );

      expect(again!.seatLabels, first!.seatLabels);
      expect(await fixture.ledgerRowsFor(settled.bookingId), rows);
      expect(await fixture.bookingSeatLabels(settled.bookingId), ['5A']);
    });

    test(
      'a capture that arrives after the seats went back moves nobody',
      () async {
        final settled = await paid();
        await fixture.lapseChangeOrder(settled.changeId);

        // The sweeper put the seats back on sale before the money landed. The
        // honest outcome is a captured intent somebody has to refund, not a
        // passenger dropped onto a seat that belongs to somebody else now.
        await db.transaction(const DbScope.worker(), (tx) async {
          await tx.execute(
            Sql.named('''
            UPDATE seats SET state = 'available', hold_id = NULL,
                             held_until = NULL
             WHERE hold_id = (SELECT hold_id FROM booking_changes
                               WHERE id = @id)
          '''),
            parameters: {'id': TypedValue(Type.uuid, settled.changeId)},
            ignoreRows: true,
          );
        });

        final applied = await desk.applyPaidChange(
          changeId: settled.changeId,
          intentId: settled.intentId,
          posting: Postings.railCapture(
            operatorId: operatorId,
            rail: railId,
            fare: const Money.xaf(1500),
            serviceFee: const Money.xaf(0),
            commission: const Money.xaf(75),
          ).valueOrNull!,
        );

        expect(applied, isNull);
        expect(
          (await fixture.changeOrder(settled.changeId))!['state'],
          'expired',
        );
        expect(await fixture.bookingSeatLabels(settled.bookingId), ['1A']);
      },
    );
  });
}
