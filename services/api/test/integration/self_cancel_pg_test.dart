@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/self_cancellation.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_self_cancellation.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The traveller cancelling their own booking, against a real database
/// (`01-feature-spec.md` §8.2).
///
/// Everything worth asserting here is about a boundary or a balance: that a
/// stranger's reference is invisible rather than refused, that the seat is
/// genuinely back on sale in the same transaction, that the ledger still
/// balances at COMMIT, and that two taps on a dropped connection produce one
/// cancellation.
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
  late PostgresSelfCancellation cancellations;
  late String operatorId;
  late String staffId;
  late String stationId;

  final now = DateTime.utc(2028, 6, 1, 6);

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(37)),
    );
    cancellations = PostgresSelfCancellation(db, random: Random(37));
    operatorId = PgFixture.operatorId;
    staffId = await fixture.traveller('cancel-actor', name: 'Vendeur');
    stationId = await fixture.station('BZV', 'Agence Annulations');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  RefundPolicy terms({
    int hours = 24,
    int bps = 9000,
    RefundDestination destination = RefundDestination.agencyCash,
  }) => RefundPolicy(
    id: 'pending',
    version: 0,
    tiers: [
      RefundTier(
        minLeadTime: Duration(hours: hours),
        rateBps: bps,
      ),
    ],
    destination: destination,
  );

  /// A reservation on a fresh departure, under [policy], not yet paid.
  Future<({String ref, String id, String userId, Money fare})> reserved({
    RefundPolicy? policy,
    Duration lead = const Duration(days: 5),
    String seat = '1A',
  }) async {
    if (policy != null) {
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
    }

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

    return (
      ref: booking.ref.value,
      id: booking.id,
      userId: await fixture.purchaserOf(booking.id),
      fare: booking.fare,
    );
  }

  /// The same, paid for in cash at a counter.
  Future<({String ref, String id, String userId, Money fare})> sold({
    RefundPolicy? policy,
    Duration lead = const Duration(days: 5),
    String seat = '1A',
  }) async {
    final booking = await reserved(policy: policy, lead: lead, seat: seat);
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
    return booking;
  }

  group('what the sheet says', () {
    test('an unpaid reservation is a release, and quotes nothing', () async {
      final booking = await reserved(policy: terms());

      final offer = await cancellations.offer(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      // The commonest cancellation in the system. Calling it a refund would
      // put a claim code on a screen for nought francs.
      expect(offer!.kind, CancellationKind.release);
      expect(offer.quote, isNull);
      expect(offer.seatCount, 1);
      expect(offer.originCity, isNotEmpty);
    });

    test('a paid booking quotes the terms it was sold under', () async {
      final booking = await sold(policy: terms());

      final offer = await cancellations.offer(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      expect(offer!.kind, CancellationKind.claimAtCounter);
      // 90% of a 9 000 fare. The service fee is ours and these terms do not
      // give it back.
      expect(offer.quote!.refundable, const Money.xaf(8100));
      expect(offer.policyLinesLength, greaterThan(0));

      // The operator now writes more generous terms. This booking must not
      // move — ADR-0015 rule 1.
      final newer = await console.saveRefundPolicy(
        operatorId: operatorId,
        name: 'Generous',
        policy: terms(bps: 10000),
        actorUserId: staffId,
      );
      await console.setDefaultRefundPolicy(
        operatorId: operatorId,
        policyId: newer.id,
        version: newer.version,
      );

      final again = await cancellations.offer(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );
      expect(again!.quote!.refundable, const Money.xaf(8100));
    });

    test('a stranger sees nothing, not a refusal', () async {
      final booking = await sold(policy: terms());
      final stranger = await fixture.traveller('cancel-stranger');

      // Identical to a reference that does not exist, and identical without
      // any code deciding that it should be: the read runs as them.
      expect(
        await cancellations.offer(
          bookingRef: booking.ref,
          userId: stranger,
          now: now,
        ),
        isNull,
      );
    });

    test('inside the last band, it warns rather than refuses', () async {
      final booking = await sold(
        policy: terms(hours: 48),
        lead: const Duration(hours: 6),
      );

      final offer = await cancellations.offer(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      // Somebody who knows they cannot travel would rather free the seat than
      // no-show. The button stays; the sentence above it changes.
      expect(offer!.kind, CancellationKind.claimAtCounter);
      expect(offer.givesNothingBack, isTrue);
      expect(offer.refusal, isNull);
    });

    test('a departed coach is refused, and says so', () async {
      final booking = await sold(
        policy: terms(),
        lead: const Duration(hours: 1),
      );

      final offer = await cancellations.offer(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now.add(const Duration(hours: 2)),
      );

      expect(offer!.refusal, isA<CoachHasLeft>());
      expect(offer.kind, isNull);
    });
  });

  group('cancelling', () {
    test('an unpaid reservation frees the seat and owes nothing', () async {
      final booking = await reserved(policy: terms());

      final result = await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      expect(result!.done!.kind, CancellationKind.release);
      expect(result.done!.refunded, isNull);
      expect(await fixture.bookingState(booking.ref), 'cancelled');
      // The point of the whole feature: a seat freed at 22:00 the night
      // before is a seat somebody else buys.
      expect(await fixture.seatState(booking.id, '1A'), 'available');
      // And no refund row, because a refund of nought is a row somebody
      // would later try to pay.
      expect(await fixture.refundFor(booking.id), isNull);
    });

    test(
      'a paid booking is refunded as a claim, and the ledger balances',
      () async {
        final booking = await sold(policy: terms());

        final result = await cancellations.cancel(
          bookingRef: booking.ref,
          userId: booking.userId,
          now: now,
        );

        expect(result!.done!.refunded, const Money.xaf(8100));
        expect(result.done!.claimCode, isNotNull);
        expect(result.done!.claimExpiresAt, isNotNull);

        final refund = await fixture.refundFor(booking.id);
        expect(refund!['state'], 'claim_issued');
        expect(refund['destination'], 'agencyCash');
        // Not involuntary: the operator did nothing wrong, and marking it so
        // would exempt the booking from every fee it agreed to.
        expect(refund['involuntary'], isFalse);

        expect(await fixture.seatState(booking.id, '1A'), 'available');
        expect(await fixture.voidedTickets(booking.id), 1);
        // Checked by the deferred constraint at COMMIT, not by this assertion —
        // which is the point of asserting it.
        expect(await fixture.unbalancedTxnCount(), 0);
        // Negative because a payable is a credit balance: we owe the traveller
        // 8 100, and the operator's payable has come down by the same.
        expect(
          await fixture.accountBalance('payable:refund:${booking.id}'),
          -8100,
        );
      },
    );

    test(
      'a wallet policy owes the money without pretending it moved',
      () async {
        final booking = await sold(
          policy: terms(destination: RefundDestination.source),
        );

        final result = await cancellations.cancel(
          bookingRef: booking.ref,
          userId: booking.userId,
          now: now,
        );

        // Paid in cash at a counter, so there is no source to send it back to
        // whatever the policy field says — the domain decides that, and it
        // decides it the same way here as it does on the screen.
        expect(result!.done!.kind, CancellationKind.claimAtCounter);
        expect(result.done!.claimCode, isNotNull);
      },
    );

    test('cancelling twice is one cancellation', () async {
      final booking = await sold(policy: terms());

      await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );
      final second = await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      // Two taps on a dropped connection. One refund, and the second answer
      // is a sentence rather than a second payout.
      expect(second!.refusal, isA<NothingToCancel>());
      expect(await fixture.refundCount(booking.id), 1);
    });

    test('a stranger cannot cancel somebody else', () async {
      final booking = await sold(policy: terms());
      final stranger = await fixture.traveller('cancel-thief');

      final result = await cancellations.cancel(
        bookingRef: booking.ref,
        userId: stranger,
        now: now,
      );

      // Null, not a refusal — the same answer as a reference that does not
      // exist, so a stranger cannot measure which one they typed.
      expect(result, isNull);
      expect(await fixture.bookingState(booking.ref), 'confirmed');
    });

    test('the terms giving nothing back still frees the seat', () async {
      final booking = await sold(
        policy: terms(hours: 48),
        lead: const Duration(hours: 6),
      );

      final result = await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      expect(result!.done!.refunded, const Money.xaf(0));
      expect(await fixture.bookingState(booking.ref), 'cancelled');
      expect(await fixture.seatState(booking.id, '1A'), 'available');
      // No money moved: no refund row, and the only ledger entries against
      // this booking are still the three the cash sale wrote.
      expect(await fixture.refundFor(booking.id), isNull);
      expect(await fixture.ledgerRowsFor(booking.id), 3);
    });

    test('a departed coach refuses, and the booking is untouched', () async {
      final booking = await sold(
        policy: terms(),
        lead: const Duration(hours: 1),
      );

      final result = await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now.add(const Duration(hours: 2)),
      );

      expect(result!.refusal, isA<CoachHasLeft>());
      expect(await fixture.bookingState(booking.ref), 'confirmed');
      expect(await fixture.voidedTickets(booking.id), 0);
    });

    test('the claim code goes out by SMS as well as onto the screen', () async {
      final booking = await sold(policy: terms());

      await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      // Queued, never sent inline (ADR-0019). A code that only ever existed
      // on one screen is a code somebody loses.
      expect(await fixture.outboxCount('booking.cancelled', booking.id), 1);
    });

    test('the traveller is named as the actor', () async {
      final booking = await sold(policy: terms());

      await cancellations.cancel(
        bookingRef: booking.ref,
        userId: booking.userId,
        now: now,
      );

      final audit = await fixture.auditFor(operatorId);
      expect(
        audit.where((row) => row['action'] == 'booking.self_cancelled'),
        isNotEmpty,
      );
    });
  });
}

extension on CancellationOffer {
  int get policyLinesLength => policy?.describe().length ?? 0;
}
