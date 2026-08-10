@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/adapters/fake_payment_gateway.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/pay_for_booking.dart';
import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_directory.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_payment_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Mobile money, against the database that will actually arbitrate it.
///
/// The in-memory suite proves the state machine. This file exists for the
/// three claims a Dart map cannot make:
///
///   * **the commission is the one this operator signed** — read from their
///     row at the moment the fare settles, not from a constant in a binary;
///   * a capture is **all of it or none of it** — booking confirmed, seat
///     sold, ledger balanced at COMMIT, ticket issued;
///   * a callback and a poll arriving together produce **one** of everything,
///     which is the normal case on these rails rather than the exception.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  const railId = 'cg.fake_money';

  /// An MTN number, so the rail's own carrier check has something real to
  /// agree with.
  const payer = '242061234567';

  late PgFixture fixture;
  late Database db;
  late PostgresBookingStore bookings;
  late PostgresPaymentStore payments;
  late PostgresSeatInventory inventory;
  late FakePaymentGateway rail;
  late PayForBooking pay;
  late HoldSeats hold;
  late ReserveBooking reserve;
  late String userId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    inventory = PostgresSeatInventory(db);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(7)),
    );
    payments = PostgresPaymentStore(db);
    rail = FakePaymentGateway(railId: railId);
    pay = PayForBooking(
      payments: payments,
      bookings: bookings,
      operators: PostgresOperatorDirectory(db),
      gateways: {railId: rail},
    );
    hold = HoldSeats(inventory: inventory);
    reserve = ReserveBooking(bookings: bookings, random: Random(13));
    userId = await fixture.traveller('910001', name: 'Aline M.');
    await fixture.collectionAccount(railId: railId, msisdn: '242060000001');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  setUp(() => fixture.agreeCommission(500));

  var seq = 0;
  String key() => 'pay-it-${++seq}-${DateTime.now().microsecondsSinceEpoch}';

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

  Future<({BookingRecord booking, String intentId})> pending() async {
    final booking = await reserveOne();
    final started = await pay.start(
      bookingId: booking.id,
      userId: userId,
      railId: railId,
      payerMsisdn: payer,
      accountMsisdn: payer,
      idempotencyKey: key(),
    );
    return (booking: booking, intentId: started.valueOrNull!.id);
  }

  test('a started payment is pending, and the booking is not yet paid', () async {
    final it = await pending();

    final intent = await fixture.intentColumns(it.intentId);
    expect(intent['state'], 'pending');
    expect(intent['msisdn'], payer);
    expect(intent['amount_minor'], 12300);
    // Nobody has typed a PIN. A ticket here would be a free journey.
    expect(await fixture.ticketCount(it.booking.id), 0);
    expect(await fixture.ledgerRowsFor(it.booking.id), 0);
  });

  test('settling nets the commission THIS operator negotiated', () async {
    // 7.5%. Arbitrary on purpose: nothing in the code knows this number, and
    // the ledger has to follow the contract rather than a constant.
    await fixture.agreeCommission(750);
    final it = await pending();
    rail.settlesAfter(0);

    await pay.reconcile(intentId: it.intentId, railId: railId);

    final balances = await fixture.accountBalances(it.booking.id);
    // Credits are negative in the signed view. 12 000 at 750 bps is 900, so
    // the operator is credited 11 100 rather than credited in full and
    // invoiced for the rest — an operator who has to be invoiced is one who
    // eventually does not pay.
    expect(balances['psp:$railId:clearing'], 12300);
    expect(balances['payable:operator:${it.booking.operatorId}'], -11100);
    expect(balances['revenue:commission'], -900);
    expect(balances['revenue:service_fee'], -300);
    expect(await fixture.unbalancedTxnCount(), 0);
  });

  test('a capture confirms, sells the seat and issues the ticket', () async {
    final it = await pending();
    rail.settlesAfter(0);

    await pay.reconcile(intentId: it.intentId, railId: railId);

    final states = await fixture.seatStates(it.booking.departureId);
    expect(states['1A'], 'sold');
    expect(await fixture.ticketCount(it.booking.id), 1);
    expect(await fixture.outboxCount('booking.confirmed', it.booking.id), 1);

    final columns = await fixture.bookingPaymentColumns(it.booking.id);
    expect(columns['payment_method'], railId);
    // The bearer code is erased when the money is taken, whichever rail took
    // it: whoever holds it can collect the booking.
    expect(columns['payment_code'], isNull);
  });

  test('a callback and a poll arriving together settle once', () async {
    final it = await pending();
    rail.settlesAfter(0);

    await Future.wait([
      pay.reconcile(intentId: it.intentId, railId: railId, source: 'callback'),
      pay.reconcile(intentId: it.intentId, railId: railId),
    ]);

    // One capture: one set of ledger rows, one ticket, one confirmation. Two
    // would be a traveller charged once and an operator credited twice.
    expect(await fixture.ledgerRowsFor(it.booking.id), 4);
    expect(await fixture.ticketCount(it.booking.id), 1);
    expect(await fixture.unbalancedTxnCount(), 0);
  });

  test('the ticket a traveller gets back can actually be presented', () async {
    final it = await pending();
    rail.settlesAfter(0);
    await pay.reconcile(intentId: it.intentId, railId: railId);

    final mine = await bookings.forTraveller(userId);
    final ticket = mine.firstWhere((b) => b.id == it.booking.id).tickets.single;

    // The QR the screen renders decodes to this booking and this seat. Read
    // back out of Postgres rather than off the object the capture returned,
    // because BYTEA and TIMESTAMPTZ are where a round trip goes wrong.
    final decoded = TicketPayload.decode(ticket.payload);
    expect(decoded.valueOrNull!.payload.bookingRef, it.booking.ref.value);
    expect(decoded.valueOrNull!.payload.seatLabel, '1A');

    // And the six digits under it are computable on the device, which is the
    // whole reason the secret travels: a screenshot scans, and fails here.
    expect(ticket.rotatingSecret, hasLength(32));
    final now = DateTime.now().toUtc();
    final code = RotatingCode.current(
      secret: ticket.rotatingSecret,
      now: now,
      mac: const HmacSha256Authenticator(),
    );
    expect(
      RotatingCode.isFresh(
        presented: code,
        secret: ticket.rotatingSecret,
        now: now,
        mac: const HmacSha256Authenticator(),
      ),
      isTrue,
    );
    expect(ticket.isVoid, isFalse);
  });

  test('every answer is written, whether or not it moved anything', () async {
    final it = await pending();
    rail.settlesAfter(0);
    await pay.reconcile(intentId: it.intentId, railId: railId);
    await pay.reconcile(intentId: it.intentId, railId: railId);

    // `payment_events` is append-only and is the only thing that settles a
    // dispute six weeks later, so a refused transition is still recorded.
    final intent = await fixture.intentColumns(it.intentId);
    expect(intent['state'], 'captured');
    expect(intent['events'] as int, greaterThanOrEqualTo(3));
  });
}
