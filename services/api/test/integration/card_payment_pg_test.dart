@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/adapters/fake_payment_gateway.dart';
import 'package:bel_api/src/adapters/hosted_checkout_gateway.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/pay_for_booking.dart';
import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/application/ports/payment_gateway.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_directory.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_payment_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// A card, against the database that will actually arbitrate it.
///
/// The unit suite proves the branch. This file exists for the claims only the
/// schema can make, and they are the ones a card rail gets wrong:
///
///   * a card intent opens **with no operator collection account**, because
///     the money lands in the processor's merchant account and there is no
///     wallet to pay into — while a wallet rail with no account is still
///     refused, by the same query;
///   * the page the traveller was sent to **survives**, including across a
///     poll the state machine refuses, because an app killed mid-checkout
///     must be offered the same page rather than a second transaction;
///   * a captured card settles through **the same ledger** as a wallet, at
///     the commission this operator signed. A rail is a way money arrives,
///     not a second accounting system.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  const cardRail = 'cg.card.test';
  const walletRail = 'cg.wallet.test';
  const payer = '242061234567';

  late PgFixture fixture;
  late Database db;
  late PostgresBookingStore bookings;
  late PostgresPaymentStore payments;
  late SandboxCheckoutGateway card;
  late PayForBooking pay;
  late HoldSeats hold;
  late ReserveBooking reserve;
  late String userId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(21)),
    );
    payments = PostgresPaymentStore(db);
    card = SandboxCheckoutGateway(railId: cardRail);
    pay = PayForBooking(
      payments: payments,
      bookings: bookings,
      operators: PostgresOperatorDirectory(db),
      gateways: {cardRail: card},
    );
    hold = HoldSeats(inventory: PostgresSeatInventory(db));
    reserve = ReserveBooking(bookings: bookings, random: Random(23));
    userId = await fixture.traveller('910077', name: 'Aline M.');
    // Deliberately none for `cardRail`. That absence is what half of this
    // file is about.
    await fixture.collectionAccount(railId: walletRail, msisdn: payer);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  setUp(() => fixture.agreeCommission(500));

  var seq = 0;
  String key() => 'card-${++seq}-${DateTime.now().microsecondsSinceEpoch}';

  Future<BookingRecord> reserveOne() async {
    final departureId = await fixture.departure(seatLabels: const ['1A']);
    final claimed = await hold(
      departureId: departureId,
      seatLabels: const ['1A'],
      userId: userId,
      idempotencyKey: key(),
    );
    final result = await reserve(
      holdId: claimed.valueOrNull!.id,
      userId: userId,
      passengers: const [PassengerDto(fullName: 'Aline M.', seatLabel: '1A')],
    );
    return result.valueOrNull!;
  }

  Future<({BookingRecord booking, String intentId})> checkout() async {
    final booking = await reserveOne();
    final started = await pay.start(
      bookingId: booking.id,
      userId: userId,
      railId: cardRail,
      payerMsisdn: null,
      accountMsisdn: null,
      idempotencyKey: key(),
      returnUrl: 'billetenligne://payment/return',
    );
    return (booking: booking, intentId: started.valueOrNull!.id);
  }

  test('a card opens with no wallet to pay into', () async {
    final it = await checkout();

    final intent = await fixture.intentColumns(it.intentId);
    expect(intent['state'], 'pending');
    expect(intent['hosted_checkout'], isTrue);
    // No number on either side. The operator has no account on this rail and
    // does not need one: the money lands with the processor and reaches them
    // through the payout run, like every other franc.
    expect(intent['msisdn'], isNull);
    expect(intent['checkout_url'], startsWith('https://checkout.invalid/pay/'));
    expect(await fixture.ticketCount(it.booking.id), 0);
    expect(await fixture.ledgerRowsFor(it.booking.id), 0);
  });

  test('a wallet rail with no verified account is still refused', () async {
    // The same query decides both. Loosening it for cards must not have
    // loosened it for wallets — that would push a prompt at a number nobody
    // has verified, which is how money reaches the wrong person.
    final booking = await reserveOne();
    final wallet = PayForBooking(
      payments: payments,
      bookings: bookings,
      operators: PostgresOperatorDirectory(db),
      // A push rail, on purpose: the loosening is for rails that have no
      // wallet at all, and a wallet rail must not have inherited it.
      gateways: {
        'cg.unaccounted': FakePaymentGateway(railId: 'cg.unaccounted'),
      },
    );

    final result = await wallet.start(
      bookingId: booking.id,
      userId: userId,
      railId: 'cg.unaccounted',
      payerMsisdn: payer,
      accountMsisdn: payer,
      idempotencyKey: key(),
    );

    expect(result.isOk, isFalse);
  });

  test('the page survives a poll that changes nothing', () async {
    final it = await checkout();
    final opened = (await fixture.intentColumns(it.intentId))['checkout_url'];
    card.statusScript.add(const PaymentOutcome(state: PaymentState.pending));

    await pay.reconcile(intentId: it.intentId, railId: cardRail);

    final after = await fixture.intentColumns(it.intentId);
    // `pending → pending` is a transition the store refuses, and the URL has
    // to come back anyway — the app that was killed mid-checkout is polling,
    // and a blank screen here means a second charge.
    expect(after['checkout_url'], opened);
    expect(after['state'], 'pending');
  });

  test('a captured card settles through the same ledger', () async {
    await fixture.agreeCommission(750);
    final it = await checkout();
    card.statusScript.add(const PaymentOutcome(state: PaymentState.captured));

    await pay.reconcile(intentId: it.intentId, railId: cardRail);

    final balances = await fixture.accountBalances(it.booking.id);
    // 12 000 at 750 bps is 900. Identical to the wallet suite's arithmetic,
    // on purpose: a card is a way money arrives, not a second set of books.
    final owed = balances.entries.singleWhere(
      (e) => e.key.startsWith('payable:operator'),
    );
    expect(owed.value, -11100);
    // And the money came in through the card rail's own clearing account,
    // which is what the payout run later drains.
    expect(balances['psp:$cardRail:clearing'], 12300);
    expect(balances.values.fold(0, (a, b) => a + b), 0);
    expect(await fixture.ticketCount(it.booking.id), 1);
  });

  test('the ticket is issued once, however the money is confirmed', () async {
    final it = await checkout();
    card.statusScript.addAll([
      const PaymentOutcome(state: PaymentState.captured),
      const PaymentOutcome(state: PaymentState.captured),
    ]);

    // A callback and a poll landing together is the normal case on a card
    // rail too: the return URL wakes one while the poller is already asking.
    await Future.wait([
      pay.reconcile(intentId: it.intentId, railId: cardRail),
      pay.reconcile(intentId: it.intentId, railId: cardRail),
    ]);

    expect(await fixture.ticketCount(it.booking.id), 1);
    expect(await fixture.ledgerRowsFor(it.booking.id), greaterThan(0));
    final balances = await fixture.accountBalances(it.booking.id);
    expect(balances.values.fold(0, (a, b) => a + b), 0);
  });
}
