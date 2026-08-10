@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Money, against the database that will actually arbitrate it.
///
/// The in-memory suite proves the rules. This file exists for the claims a
/// Dart map cannot make, and every one of them is about a transaction:
///
///   * confirming is **all of it or none of it** — seat sold, booking written,
///     ledger posted, ticket issued. Any prefix committing alone is a specific
///     disaster, and the worst (booking, no ledger) is indistinguishable from
///     theft at the end of the month;
///   * the ledger **balances at COMMIT**, enforced by a deferred constraint
///     trigger that no Dart handler can reach;
///   * two vendors collecting one reservation produce **one** sale;
///   * a reserved seat stays `held`, so nothing can board before payment.
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
  late PostgresSeatInventory inventory;
  late HoldSeats hold;
  late ReserveBooking reserve;
  late String userId;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    inventory = PostgresSeatInventory(db);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(3)),
    );
    hold = HoldSeats(inventory: inventory);
    reserve = ReserveBooking(bookings: bookings, random: Random(5));
    userId = await fixture.traveller('900001', name: 'Aline M.');
    stationId = await fixture.station('BZV', 'Agence Centre-ville');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String key() => 'book-it-${++seq}-${DateTime.now().microsecondsSinceEpoch}';

  Future<BookingRecord> reserveOne({
    List<String> seats = const ['1A'],
    String? forUser,
  }) async {
    final departureId = await fixture.departure(seatLabels: seats);
    final claimed = await hold(
      departureId: departureId,
      seatLabels: seats,
      userId: forUser ?? userId,
      idempotencyKey: key(),
    );

    final result = await reserve(
      holdId: claimed.valueOrNull!.id,
      userId: forUser ?? userId,
      passengers: [
        for (final s in seats) PassengerDto(fullName: 'Aline M.', seatLabel: s),
      ],
    );
    return result.valueOrNull!;
  }

  Future<BookingRecord?> capture(BookingRecord booking) => bookings.captureCash(
    bookingId: booking.id,
    operatorId: booking.operatorId,
    stationId: stationId,
    soldByUserId: null,
    posting: Postings.cashSale(
      operatorId: booking.operatorId,
      stationId: stationId,
      fare: booking.fare,
      serviceFee: booking.serviceFee,
    ).valueOrNull!,
  );

  group('reserving', () {
    test('the seat stays held, so nothing can board before payment', () async {
      final booking = await reserveOne();

      final states = await fixture.seatStates(booking.departureId);
      // Not `sold`. Selling before payment means a ticket that can board
      // before anybody has paid, and `bel_public` cannot write that state at
      // all — which is the point of migration 0005.
      expect(states['1A'], 'held');
      expect(booking.tickets, isEmpty);
    });

    test('no ledger row exists before the money moves', () async {
      final booking = await reserveOne();

      // Writing them now and reversing them later is how a ledger stops being
      // a record of what happened and becomes a record of what we expected.
      expect(await fixture.ledgerRowsFor(booking.id), 0);
    });

    test('the price is the seat row, read in the same transaction', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fareMinor: 15500,
      );
      final claimed = await hold(
        departureId: departureId,
        seatLabels: ['1A'],
        userId: userId,
        idempotencyKey: key(),
      );

      final booking = (await reserve(
        holdId: claimed.valueOrNull!.id,
        userId: userId,
        passengers: [const PassengerDto(fullName: 'A', seatLabel: '1A')],
      )).valueOrNull!;

      expect(booking.fare, const Money.xaf(15500));
      expect(booking.total, const Money.xaf(15800));
    });

    test('a hold cannot be spent twice', () async {
      final departureId = await fixture.departure(seatLabels: ['1A']);
      final claimed = await hold(
        departureId: departureId,
        seatLabels: ['1A'],
        userId: userId,
        idempotencyKey: key(),
      );
      final holdId = claimed.valueOrNull!.id;

      final both = await Future.wait([
        reserve(
          holdId: holdId,
          userId: userId,
          passengers: [const PassengerDto(fullName: 'A', seatLabel: '1A')],
        ),
        reserve(
          holdId: holdId,
          userId: userId,
          passengers: [const PassengerDto(fullName: 'A', seatLabel: '1A')],
        ),
      ]);

      // `UPDATE holds SET state='consumed' WHERE state='active'` settles it.
      // A read-then-write pair would leave both believing they were first,
      // and a coach with two bookings for seat 1A.
      expect(both.where((r) => r.isOk).length, 1);
    });
  });

  group('taking the cash', () {
    test('sells the seat, posts the ledger and issues the ticket', () async {
      final booking = await reserveOne();
      final confirmed = await capture(booking);

      expect(confirmed!.state, 'confirmed');
      expect(confirmed.tickets, hasLength(1));

      final states = await fixture.seatStates(booking.departureId);
      expect(states['1A'], 'sold');

      // Three debits/credits summing to zero, and the ticket row exists.
      expect(await fixture.ledgerRowsFor(booking.id), 3);
      expect(await fixture.ticketCount(booking.id), 1);
    });

    test('the posting balances, as Postgres computes it', () async {
      final booking = await reserveOne();
      await capture(booking);

      // Asked of the `ledger_txn_balances` view rather than summed in Dart:
      // a test that derives the balance agrees with the query by sharing its
      // bug, and this is the invariant the whole ledger rests on.
      expect(await fixture.unbalancedTxnCount(), 0);
    });

    test('the till is debited the full amount the traveller paid', () async {
      final booking = await reserveOne();
      await capture(booking);

      final balances = await fixture.accountBalances(booking.id);
      expect(balances['cash:${booking.operatorId}:$stationId:till'], 12300);
      // Credits are negative in the signed view. Zero commission on cash by
      // design (product brief D-04) — the operator is owed the whole fare.
      expect(balances['payable:operator:${booking.operatorId}'], -12000);
      expect(balances['revenue:service_fee'], -300);
      expect(balances.containsKey('revenue:commission'), isFalse);
    });

    test('two vendors collecting one reservation produce one sale', () async {
      final booking = await reserveOne();

      final both = await Future.wait([capture(booking), capture(booking)]);

      expect(both.whereType<BookingRecord>().length, 1);
      // One sale means one set of ledger rows. Two would be a passenger
      // charged twice and an operator credited twice.
      expect(await fixture.ledgerRowsFor(booking.id), 3);
      expect(await fixture.ticketCount(booking.id), 1);
    });

    test('the payment code is erased when the money is taken', () async {
      final booking = await reserveOne();

      expect(
        await bookings.byPaymentCode(
          code: booking.paymentCode!,
          operatorId: booking.operatorId,
        ),
        isNotNull,
      );

      await capture(booking);

      // It is a bearer: whoever holds it can pay for and collect this
      // booking. One that outlives its purpose is one somebody finds.
      expect(
        await bookings.byPaymentCode(
          code: booking.paymentCode!,
          operatorId: booking.operatorId,
        ),
        isNull,
      );
    });

    test('a confirmed booking says how and when it was paid', () async {
      final booking = await reserveOne();
      await capture(booking);

      // `bookings_confirmed_is_paid` refuses the row otherwise. Without it the
      // failure mode is a confirmed booking with a ticket, a boarded
      // passenger and no money anywhere.
      final row = await fixture.bookingPaymentColumns(booking.id);
      expect(row['payment_method'], 'cash');
      expect(row['paid_at'], isNotNull);
      expect(row['station_id'], stationId);
    });

    test('the ticket is queued for delivery exactly once', () async {
      final booking = await reserveOne();
      await capture(booking);
      await capture(booking);

      // `(event, channel, recipient)` is unique, so a retried drain cannot
      // double-send. Nothing erodes trust like two conflicting messages about
      // one payment (ADR-0019 rule 2).
      expect(await fixture.outboxCount('booking.confirmed', booking.id), 1);
    });
  });

  test('a traveller sees their own bookings and no stranger\'s', () async {
    final other = await fixture.traveller('900002', name: 'Serge N.');
    await reserveOne(seats: ['1A'], forUser: other);

    final mine = await bookings.forTraveller(userId);
    final theirs = await bookings.forTraveller(other);

    expect(mine, isNotEmpty);
    expect(theirs, hasLength(1));
    expect(
      mine
          .map((b) => b.id)
          .toSet()
          .intersection(theirs.map((b) => b.id).toSet()),
      isEmpty,
    );
  });
}
