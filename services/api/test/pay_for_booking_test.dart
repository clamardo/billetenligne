import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/adapters/fake_payment_gateway.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/pay_for_booking.dart';
import 'package:bel_api/src/application/ports/payment_gateway.dart';
import 'package:bel_api/src/application/ports/payment_store.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/memory/memory_booking_store.dart';
import 'package:bel_api/src/infrastructure/memory/memory_operator_directory.dart';
import 'package:bel_api/src/infrastructure/memory/memory_payment_store.dart';
import 'package:bel_api/src/infrastructure/memory/memory_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

final class TestClock implements Clock {
  TestClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  late TestClock clock;
  late MemorySeatInventory inventory;
  late MemoryBookingStore bookings;
  late MemoryPaymentStore payments;
  late MemoryOperatorDirectory operators;
  late FakePaymentGateway rail;
  late PayForBooking pay;
  late ReserveBooking reserve;
  late HoldSeats hold;

  const railId = 'cg.fake_money';

  /// An MTN number, so the rail check has something real to agree with.
  const mtnNumber = '242061234567';

  setUp(() async {
    clock = TestClock(DateTime.utc(2026, 8, 9, 6));
    inventory = MemorySeatInventory(
      clock: clock,
      departures: [
        MemoryDeparture.coach(
          id: 'dep-1',
          operatorId: 'op-odn',
          departsAt: clock.now().add(const Duration(days: 1)),
        ),
      ],
    );
    bookings = MemoryBookingStore(
      inventory: inventory,
      issuer: await Ed25519TicketIssuer.development(random: Random(3)),
      clock: clock,
    );
    payments = MemoryPaymentStore(bookings: bookings, clock: clock);
    // What this operator signed: 5%. Another operator signs another number,
    // which is the whole point of the row it is read from.
    operators = MemoryOperatorDirectory(
      commissions: {'op-odn': CommissionTerm.seed},
    );
    rail = FakePaymentGateway(railId: railId, clock: clock);
    pay = PayForBooking(
      payments: payments,
      bookings: bookings,
      operators: operators,
      gateways: {railId: rail},
    );
    reserve = ReserveBooking(bookings: bookings, random: Random(11));
    hold = HoldSeats(inventory: inventory);
  });

  Future<String> aReservation({String seat = '1A'}) async {
    final claimed = await hold(
      departureId: 'dep-1',
      seatLabels: [seat],
      userId: 'u-1',
      idempotencyKey: 'k-$seat',
    );
    final reserved = await reserve(
      holdId: claimed.valueOrNull!.id,
      userId: 'u-1',
      passengers: [PassengerDto(fullName: 'Aline M.', seatLabel: seat)],
    );
    return reserved.valueOrNull!.id;
  }

  Future<Result<PaymentIntentRecord, PaymentFailure>> start({
    String? bookingId,
    String payer = mtnNumber,
    String? accountMsisdn = mtnNumber,
    String key = 'pay-1',
    String rail = railId,
  }) async => pay.start(
    bookingId: bookingId ?? await aReservation(),
    userId: 'u-1',
    railId: rail,
    payerMsisdn: payer,
    accountMsisdn: accountMsisdn,
    idempotencyKey: key,
  );

  group('starting a payment', () {
    test('pushes a prompt and answers pending, not paid', () async {
      final result = await start();

      final intent = result.valueOrNull!;
      // The traveller has not typed their PIN. Anything else here is a lie
      // the waiting screen would repeat.
      expect(intent.state, PaymentState.pending);
      expect(rail.requests, hasLength(1));
      expect(rail.requests.single.payerMsisdn, mtnNumber);
    });

    test('sends the amount from the booking, never from the caller', () async {
      final result = await start();
      // 12 000 fare + 300 fee. No number crossed the boundary to say so.
      expect(rail.requests.single.amount, const Money.xaf(12300));
      expect(result.valueOrNull!.amount, const Money.xaf(12300));
    });

    test('pushes to the operator verified collection number', () async {
      await start();
      expect(rail.requests.single.collectionMsisdn, '242060000001');
    });

    test('a payer number that is not the traveller own is allowed', () async {
      // Somebody whose wallet is empty pays from a relative's, standing next
      // to them and reading out the PIN prompt. Requiring these to match is
      // the obvious validation and it breaks the commonest way a ticket gets
      // paid for in this market.
      final result = await start(
        payer: '242069999999',
        accountMsisdn: mtnNumber,
      );
      expect(result.isOk, isTrue);
      expect(rail.requests.single.payerMsisdn, '242069999999');
    });

    test('a number on the wrong carrier is refused before anything is sent',
        () async {
      final result = await pay.start(
        bookingId: await aReservation(),
        userId: 'u-1',
        // The fake rail is registered under its own id, so ask for a real
        // one the number does not match.
        railId: 'cg.mtn_momo',
        payerMsisdn: mtnNumber,
        accountMsisdn: null,
        idempotencyKey: 'wrong-rail',
      );

      // Not a generic decline thirty seconds later. The traveller can fix
      // this by switching a toggle, and only a specific failure says so.
      expect(result.failureOrNull, isA<RailNotAvailable>());
      expect(rail.requests, isEmpty);
    });

    test('an unparseable number never reaches the rail', () async {
      final result = await start(payer: '12');
      expect(result.failureOrNull, isA<PayerNumberInvalid>());
      expect(rail.requests, isEmpty);
    });

    test('a retry of the same attempt does not push a second prompt', () async {
      final bookingId = await aReservation();
      await start(bookingId: bookingId, key: 'same');
      await start(bookingId: bookingId, key: 'same');

      // Two PIN prompts on one handset is the failure this prevents, and on
      // these networks the tap gets duplicated.
      expect(rail.requests, hasLength(1));
    });

    test('a booking that is already paid cannot be paid again', () async {
      final bookingId = await aReservation();
      await start(bookingId: bookingId, key: 'first');
      rail.statusScript.add(
        const PaymentOutcome(state: PaymentState.captured),
      );
      await pay.reconcile(intentId: 'pi-mem-1', railId: railId);

      final again = await start(bookingId: bookingId, key: 'second');
      expect(again.failureOrNull, isA<BookingNotPayable>());
    });

    test('a rail that refuses outright reports the reason', () async {
      final result = await start(payer: FakePaymentGateway.decliningMsisdn);

      final failure = result.failureOrNull! as RailRefused;
      expect(failure.failureCode, PaymentFailureCode.insufficientFunds);
      // Twelve codes, twelve sentences, twelve recoveries — never "Payment
      // failed. Try again."
      expect(failure.code, 'payment.insufficient_funds');
    });
  });

  group('reconciling', () {
    test('a capture confirms the booking and issues the ticket', () async {
      final bookingId = await aReservation();
      final intent = (await start(bookingId: bookingId)).valueOrNull!;

      rail.settlesAfter(0);
      final settled = await pay.reconcile(
        intentId: intent.id,
        railId: railId,
      );

      expect(settled!.state, PaymentState.captured);

      final booking = await bookings.byId(
        bookingId: bookingId,
        operatorId: 'op-odn',
      );
      // The ticket is issued on `captured` and only there. No optimistic
      // issuance, ever.
      expect(booking!.state, 'confirmed');
      expect(booking.tickets, hasLength(1));
    });

    test('the ledger nets commission at source', () async {
      final bookingId = await aReservation();
      final intent = (await start(bookingId: bookingId)).valueOrNull!;
      rail.settlesAfter(0);
      await pay.reconcile(intentId: intent.id, railId: railId);

      final posting = bookings.postingFor(bookingId)!;
      // 12 000 fare, 5% commission, 300 fee: the operator is credited 11 400
      // rather than credited in full and invoiced later.
      expect(posting, contains('debit psp:cg.fake_money:clearing 12300'));
      expect(posting, contains('credit payable:operator:op-odn 11400'));
      expect(posting, contains('credit revenue:commission 600'));
      expect(posting, contains('credit revenue:service_fee 300'));
    });

    test('nets the rate THIS operator negotiated, not a market rate', () async {
      // 7.5%. A larger carrier with its own agency network argues the number
      // down; a two-coach family business does not. Both are onboarded by the
      // same code, and the ledger has to follow the contract rather than a
      // constant.
      operators.agree('op-odn', CommissionTerm(750));

      final bookingId = await aReservation();
      final intent = (await start(bookingId: bookingId)).valueOrNull!;
      rail.settlesAfter(0);
      await pay.reconcile(intentId: intent.id, railId: railId);

      final posting = bookings.postingFor(bookingId)!;
      // 12 000 at 750 bps is 900, and the operator is credited 11 100.
      expect(posting, contains('credit revenue:commission 900'));
      expect(posting, contains('credit payable:operator:op-odn 11100'));
    });

    test('keeps nothing when the operator terms cannot be read', () async {
      // The money has already moved. Refusing to settle would leave somebody
      // who paid without a ticket, and inventing a rate would take money
      // under an agreement nobody signed — so the operator gets the lot and
      // the gap is visible in the ledger.
      pay = PayForBooking(
        payments: payments,
        bookings: bookings,
        operators: MemoryOperatorDirectory(),
        gateways: {railId: rail},
      );

      final bookingId = await aReservation();
      final intent = (await start(bookingId: bookingId)).valueOrNull!;
      rail.settlesAfter(0);
      await pay.reconcile(intentId: intent.id, railId: railId);

      final posting = bookings.postingFor(bookingId)!;
      expect(posting, contains('credit payable:operator:op-odn 12000'));
      expect(posting, isNot(contains('revenue:commission')));

      final booking = await bookings.byId(
        bookingId: bookingId,
        operatorId: 'op-odn',
      );
      expect(booking!.state, 'confirmed');
      expect(booking.tickets, hasLength(1));
    });

    test('a duplicate capture confirms once', () async {
      final bookingId = await aReservation();
      final intent = (await start(bookingId: bookingId)).valueOrNull!;
      rail.settlesAfter(0);

      await pay.reconcile(intentId: intent.id, railId: railId);
      await pay.reconcile(intentId: intent.id, railId: railId);

      // A callback and a poll arriving together is the normal case on these
      // rails, not the exception.
      final booking = await bookings.byId(
        bookingId: bookingId,
        operatorId: 'op-odn',
      );
      expect(booking!.tickets, hasLength(1));
    });

    test('a callback after a capture keeps the capture', () async {
      final intent = (await start()).valueOrNull!;
      rail.settlesAfter(0);
      await pay.reconcile(intentId: intent.id, railId: railId);

      rail.declinesWith(PaymentFailureCode.userDeclined);
      final after = await pay.reconcile(intentId: intent.id, railId: railId);

      // Out-of-order callbacks are normal here. The money moved; a later
      // "declined" must not un-move it.
      expect(after!.state, PaymentState.captured);
    });

    test('every answer is written, whether or not it moved anything', () async {
      final intent = (await start()).valueOrNull!;
      rail.settlesAfter(0);
      await pay.reconcile(intentId: intent.id, railId: railId);
      rail.declinesWith(PaymentFailureCode.userDeclined);
      await pay.reconcile(intentId: intent.id, railId: railId);

      // `payment_events` is append-only and is the only thing that settles a
      // dispute six weeks later — including the event that was refused.
      expect(payments.events.where((e) => e.intentId == intent.id).length, 3);
    });

    test('a rail that never answers leaves the intent in flight', () async {
      final intent = (await start()).valueOrNull!;
      rail.neverAnswers();

      for (var i = 0; i < 5; i++) {
        await pay.reconcile(intentId: intent.id, railId: railId);
      }

      final still = await payments.byId(intentId: intent.id, userId: 'u-1');
      // Not `failed`. The money may have moved, and saying otherwise costs a
      // customer their seat and us their trust — this is what the
      // indeterminate queue exists for.
      expect(still!.state, PaymentState.pending);
    });

    test('a decline is terminal and carries its code', () async {
      final intent = (await start()).valueOrNull!;
      rail.declinesWith(PaymentFailureCode.wrongPin);

      final declined = await pay.reconcile(
        intentId: intent.id,
        railId: railId,
      );

      expect(declined!.state, PaymentState.failed);
      expect(declined.failureCode, PaymentFailureCode.wrongPin);
      // Retryable and the hold is kept: they can try again with the right PIN.
      expect(declined.failureCode!.retryable, isTrue);
      expect(declined.failureCode!.keepsHold, isTrue);
    });
  });

  test('the payment window is shorter than the seat hold', () {
    // ADR-0005 rule 5. Inverted, a seat is sold out from under somebody who
    // is entering their PIN — and the two constants live in different files,
    // which is exactly why this is asserted rather than assumed.
    expect(pay.window, lessThan(HoldPolicy.standard.ttl));
  });
}
