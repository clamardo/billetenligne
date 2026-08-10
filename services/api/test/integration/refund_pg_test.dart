@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Cash refunds, against a real database.
///
/// Every claim here is about a transaction, a race, or a balance — the three
/// things a fake cannot make honest. The one that matters most is the last
/// one: after a refund is approved and collected, the debt to the traveller
/// is exactly zero and the ledger still balances, which is checked by the
/// deferred constraint trigger at COMMIT rather than by this file.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorConsole console;
  late PostgresBookingStore bookings;
  late String operatorId;
  late String staffId;
  late String stationId;

  final now = DateTime.utc(2028, 3, 1, 6);

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(21)),
    );
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('refund-actor', name: 'Vendeur');
    stationId = await fixture.station('BZV', 'Agence Refunds');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// An operator selling under [policy], and one paid booking on a departure
  /// [lead] from [now].
  Future<({String ref, String id, Money fare})> sold({
    required RefundPolicy policy,
    Duration lead = const Duration(days: 5),
    String seat = '1A',
  }) async {
    final stored = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Terms ${DateTime.now().microsecondsSinceEpoch}',
      policy: policy,
      actorUserId: staffId,
    );
    await console.setDefaultRefundPolicy(
      operatorId: operatorId,
      policyId: stored.id,
      version: stored.version,
    );

    final departureId = await fixture.departure(
      seatLabels: [seat],
      fromNow: now.difference(DateTime.now().toUtc()) + lead,
      fareMinor: 9000,
    );
    final booking = await fixture.reserve(
      db: db,
      bookings: bookings,
      departureId: departureId,
      seatLabel: seat,
      name: 'Aline M.',
    );

    final captured = await bookings.captureCash(
      bookingId: booking.id,
      operatorId: operatorId,
      stationId: stationId,
      soldByUserId: staffId,
      posting: Postings.cashSale(
        operatorId: operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );

    return (ref: captured!.ref.value, id: booking.id, fare: booking.fare);
  }

  RefundPolicy cashPolicy({int hours = 24, int bps = 9000}) => RefundPolicy(
    id: 'pending',
    version: 0,
    tiers: [
      RefundTier(
        minLeadTime: Duration(hours: hours),
        rateBps: bps,
      ),
    ],
    destination: RefundDestination.agencyCash,
  );

  test('the quote is the terms the booking was sold under', () async {
    final booking = await sold(policy: cashPolicy());

    final offer = await console.quoteRefund(
      operatorId: operatorId,
      bookingRef: booking.ref,
      now: now,
    );

    expect(offer!.isRefundable, isTrue);
    // 90% of a 9 000 fare. The service fee is ours and this policy does not
    // give it back.
    expect(offer.quote!.refundable, const Money.xaf(8100));
    expect(offer.quote!.destination, RefundDestination.agencyCash);

    // Now the operator writes more generous terms and points the default at
    // them. This booking must not move — ADR-0015 rule 1.
    final newer = await console.saveRefundPolicy(
      operatorId: operatorId,
      name: 'Generous',
      policy: cashPolicy(bps: 10000),
      actorUserId: staffId,
    );
    await console.setDefaultRefundPolicy(
      operatorId: operatorId,
      policyId: newer.id,
      version: newer.version,
    );

    final again = await console.quoteRefund(
      operatorId: operatorId,
      bookingRef: booking.ref,
      now: now,
    );
    expect(again!.quote!.refundable, const Money.xaf(8100));
  });

  test(
    'refunding releases the seat, voids the ticket and owes the money',
    () async {
      final booking = await sold(policy: cashPolicy(), seat: '2A');

      final issued = await console.refundBooking(
        operatorId: operatorId,
        bookingRef: booking.ref,
        actorUserId: staffId,
        reason: 'Traveller cancelled at the counter',
        now: now,
      );

      expect(issued!.amount, const Money.xaf(8100));
      expect(issued.state, 'claim_issued');
      // Six characters the traveller can read out over a counter.
      expect(issued.claimCode, isNotNull);
      expect(issued.claimCode!.length, 6);

      // The seat is sellable again, in the same transaction. One left sold
      // after a refund is a seat nobody can buy and nobody is sitting in.
      expect(await fixture.seatState(booking.id, '2A'), 'available');
      // Voided at approval, not at collection: a ticket whose money is already
      // owed back must not board while the cash is still in the drawer.
      expect(await fixture.voidedTickets(booking.id), greaterThan(0));
      expect(await fixture.bookingState(booking.ref), 'refunded');

      // We owe the traveller, and the operator's payable has come down by
      // exactly what they gave back.
      expect(
        await fixture.accountBalance('payable:refund:${booking.id}'),
        -8100,
      );
    },
  );

  test('a second refund of the same booking changes nothing', () async {
    final booking = await sold(policy: cashPolicy(), seat: '3A');

    final first = await console.refundBooking(
      operatorId: operatorId,
      bookingRef: booking.ref,
      actorUserId: staffId,
      reason: 'first',
      now: now,
    );
    final second = await console.refundBooking(
      operatorId: operatorId,
      bookingRef: booking.ref,
      actorUserId: staffId,
      reason: 'second',
      now: now,
    );

    // Two vendors at two windows of one agency is not hypothetical. The
    // conditional UPDATE is what makes the second a no-op rather than a
    // second payout.
    expect(first, isNotNull);
    expect(second, isNull);
    expect(await fixture.refundCount(booking.id), 1);
  });

  test('collecting the claim empties the till and clears the debt', () async {
    final booking = await sold(policy: cashPolicy(), seat: '4A');
    final issued = await console.refundBooking(
      operatorId: operatorId,
      bookingRef: booking.ref,
      actorUserId: staffId,
      reason: 'cancelled',
      now: now,
    );

    // Measured as a delta, because every sale in this suite fills the same
    // drawer — which is exactly what a real agency's till does too.
    final tillBefore = await fixture.accountBalance(
      'cash:$operatorId:$stationId:till',
    );

    final claimed = await console.claimRefund(
      operatorId: operatorId,
      claimCode: issued!.claimCode!,
      stationId: stationId,
      actorUserId: staffId,
      now: now,
    );

    expect(claimed!.amount, const Money.xaf(8100));
    // The property that matters across the pair: what we owed is created and
    // extinguished exactly, with nothing stranded in a payable.
    expect(await fixture.accountBalance('payable:refund:${booking.id}'), 0);
    // And the money left the specific drawer it will be counted out of.
    expect(
      await fixture.accountBalance('cash:$operatorId:$stationId:till'),
      tillBefore - 8100,
    );
  });

  test('a claim code is single use, whoever scans it', () async {
    final booking = await sold(policy: cashPolicy(), seat: '5A');
    final issued = await console.refundBooking(
      operatorId: operatorId,
      bookingRef: booking.ref,
      actorUserId: staffId,
      reason: 'cancelled',
      now: now,
    );

    final first = await console.claimRefund(
      operatorId: operatorId,
      claimCode: issued!.claimCode!,
      stationId: stationId,
      actorUserId: staffId,
      now: now,
    );
    final second = await console.claimRefund(
      operatorId: operatorId,
      claimCode: issued.claimCode!,
      stationId: stationId,
      actorUserId: staffId,
      now: now,
    );

    // The state moves in the same statement that reads it, so two counters
    // cannot both hand over cash.
    expect(first, isNotNull);
    expect(second, isNull);
  });

  test('another tenant cannot collect this operator\'s claim', () async {
    final booking = await sold(policy: cashPolicy(), seat: '6A');
    final issued = await console.refundBooking(
      operatorId: operatorId,
      bookingRef: booking.ref,
      actorUserId: staffId,
      reason: 'cancelled',
      now: now,
    );

    // RLS makes the row invisible, so the answer is "no such code" rather
    // than a leak — and rather than a payout from the wrong drawer.
    expect(
      await console.claimRefund(
        operatorId: '22222222-2222-2222-2222-222222222222',
        claimCode: issued!.claimCode!,
        stationId: stationId,
        actorUserId: staffId,
        now: now,
      ),
      isNull,
    );
  });

  test('outside the window, the answer is the reason, not a zero', () async {
    // A 48-hour band on a departure two hours away.
    final booking = await sold(
      policy: cashPolicy(hours: 48),
      lead: const Duration(hours: 2),
      seat: '7A',
    );

    final offer = await console.quoteRefund(
      operatorId: operatorId,
      bookingRef: booking.ref,
      now: now,
    );
    expect(offer!.isRefundable, isFalse);
    expect(offer.failureCode, 'refund.outside_window');

    // And the execution path refuses too, rather than writing a zero-amount
    // refund the schema would reject anyway.
    expect(
      await console.refundBooking(
        operatorId: operatorId,
        bookingRef: booking.ref,
        actorUserId: staffId,
        reason: 'tried anyway',
        now: now,
      ),
      isNull,
    );
  });

  test(
    'a booking sold with no terms says so, rather than inventing them',
    () async {
      await console.setDefaultRefundPolicy(
        operatorId: operatorId,
        policyId: null,
        version: null,
      );

      final departureId = await fixture.departure(
        seatLabels: ['8A'],
        fromNow:
            now.difference(DateTime.now().toUtc()) + const Duration(days: 5),
      );
      final booking = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '8A',
        name: 'Sans conditions',
      );

      final offer = await console.quoteRefund(
        operatorId: operatorId,
        bookingRef: booking.ref.value,
        now: now,
      );

      // Applying today's policy to a booking made under none is inventing a
      // contract after the fact.
      expect(offer!.policy, isNull);
      expect(offer.failureCode, 'refund.no_policy');
    },
  );
}
