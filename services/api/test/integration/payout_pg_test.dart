@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/payout_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_payouts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The payout run, against the ledger it settles (`04-payments.md` §6.2).
///
/// The domain suite proves the arithmetic. This file exists for the claims
/// only a database can make: that the amount comes from the ledger's own
/// balances rather than from a sum somebody wrote down, that the drawer is
/// cleared in the same transaction as the transfer, that one person cannot
/// both prepare and approve, and that the same week cannot be paid twice.
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
  late PostgresPayouts payouts;
  late String operatorId;
  late String preparer;
  late String approver;
  late String stationId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(random: Random(53)),
    );
    payouts = PostgresPayouts(db);
    operatorId = PgFixture.operatorId;
    preparer = await fixture.traveller('payout-prep', name: 'Préparateur');
    approver = await fixture.traveller('payout-appr', name: 'Approbateur');
    stationId = await fixture.station('BZV', 'Agence paiements');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  final from = DateTime.utc(2020, 1, 1);
  // Deliberately in the future: "everything so far" is the window a first
  // statement covers, and it is the one where the ledger balance and the line
  // items have to agree.
  final to = DateTime.now().toUtc().add(const Duration(days: 1));

  /// A cash sale of 9 000 + 300, which puts 9 300 in the drawer and makes us
  /// owe 9 000.
  Future<void> cashSale() async {
    final departureId = await fixture.departure(
      seatLabels: const ['1A'],
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
      soldByUserId: preparer,
      posting: Postings.cashSale(
        operatorId: operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );
  }

  /// A statement over its own window.
  ///
  /// Each test takes a different [window] so the one-run-per-period index
  /// does not make the suite order-dependent — and every window still ends
  /// tomorrow, because the line items are period-scoped and the sales these
  /// tests make happen now.
  Future<PayoutRun> prepared({int window = 0}) async {
    final result = await payouts.prepare(
      operatorId: operatorId,
      from: from.subtract(Duration(days: window)),
      to: to,
      actorUserId: preparer,
    );
    expect(result.isOk, isTrue, reason: '${result.failureOrNull?.code}');
    return result.valueOrNull!;
  }

  group('preparing a statement', () {
    test('the cash in the drawer is counted against what we owe', () async {
      await cashSale();

      final run = await prepared(window: 1);

      // The single most common operator question, answered by the shape of
      // the statement rather than by a support call: the 9 300 is theirs
      // already, we owe them 9 000, so the fee comes out of the difference.
      expect(run.statement.tills.minor, greaterThanOrEqualTo(9300));
      expect(run.statement.cashSalesCount, greaterThanOrEqualTo(1));
      expect(run.statement.net.minor, lessThan(run.statement.payable.minor));
    });

    test('a week of nothing but cash leaves the operator owing us', () async {
      await cashSale();
      final run = await prepared(window: 2);

      // Zero commission on cash, but the service fee is ours and it is in
      // their drawer. The netting collects it with no invoice ever raised.
      expect(run.statement.operatorOwesUs, isTrue);
      expect(run.statement.owedToUs.minor, greaterThanOrEqualTo(300));
    });

    test('the same week cannot be prepared twice', () async {
      final window = DateTime.utc(2019, 5, 1);
      await payouts.prepare(
        operatorId: operatorId,
        from: window,
        to: window.add(const Duration(days: 7)),
        actorUserId: preparer,
      );

      final again = await payouts.prepare(
        operatorId: operatorId,
        from: window,
        to: window.add(const Duration(days: 7)),
        actorUserId: preparer,
      );

      // Paying the same week twice is the one mistake here that cannot be
      // undone with an UPDATE.
      expect(again.failureOrNull, isA<PeriodAlreadyRun>());
    });

    test('an operator that does not exist is not a statement', () async {
      final refused = await payouts.prepare(
        operatorId: '00000000-0000-0000-0000-0000000000ff',
        from: from,
        to: to,
        actorUserId: preparer,
      );

      expect(refused.failureOrNull, isA<UnknownPayout>());
    });
  });

  group('approving it', () {
    test('the person who prepared it cannot approve it', () async {
      final run = await prepared(window: 3);

      final refused = await payouts.approve(
        runId: run.id,
        actorUserId: preparer,
      );

      // Two people, not two roles. One super-admin pressing both buttons is
      // a formality, and this is the largest movement of money we make.
      expect(refused.failureOrNull, isA<NeedsASecondPerson>());
    });

    test('a second person can, and it is written down', () async {
      final run = await prepared(window: 4);

      final approved = await payouts.approve(
        runId: run.id,
        actorUserId: approver,
      );

      expect(approved.valueOrNull!.state, 'approved');
      expect(approved.valueOrNull!.approvedAt, isNotNull);

      final entry = (await fixture.auditFor(operatorId)).singleWhere(
        (e) => e['action'] == 'payout.approve' && e['subject_id'] == run.id,
      );
      expect(entry['actor_id'].toString(), approver);
    });

    test('approving twice is refused, with the state it is in', () async {
      final run = await prepared(window: 5);
      await payouts.approve(runId: run.id, actorUserId: approver);

      final again = await payouts.approve(runId: run.id, actorUserId: approver);
      expect((again.failureOrNull! as WrongPayoutState).state, 'approved');
    });
  });

  group('releasing it', () {
    test('an unapproved run cannot be released', () async {
      final run = await prepared(window: 6);

      final refused = await payouts.release(
        runId: run.id,
        actorUserId: approver,
        reference: 'PAY-1',
      );

      expect((refused.failureOrNull! as WrongPayoutState).state, 'draft');
    });

    test('a negative balance is refused rather than reversed', () async {
      await cashSale();
      final run = await prepared(window: 7);
      await payouts.approve(runId: run.id, actorUserId: approver);

      final refused = await payouts.release(
        runId: run.id,
        actorUserId: approver,
        reference: 'PAY-2',
      );

      // Money moving the other way is an invoice and a conversation, not a
      // payout run with a minus sign in it.
      expect(refused.failureOrNull, isA<PayoutRefused>());
      expect(refused.failureOrNull!.code, 'payout.operator_owes_us');
    });

    test(
      'the drawer is settled in the same movement as the transfer',
      () async {
        // An online sale, so there is something to actually pay out: the rail
        // holds the money and we owe the operator the fare less commission.
        await fixture.railCapture(
          operatorId: operatorId,
          fareMinor: 90000,
          serviceFeeMinor: 300,
          commissionMinor: 4500,
        );

        final run = await prepared(window: 8);
        await payouts.approve(runId: run.id, actorUserId: approver);

        final paid = await payouts.release(
          runId: run.id,
          actorUserId: approver,
          reference: 'PAY-2026-32',
        );

        expect(paid.valueOrNull!.state, 'paid');
        expect(paid.valueOrNull!.reference, 'PAY-2026-32');

        // Both accounts are flat afterwards. Paying the net and leaving the
        // till standing would mean the same cash counted against every future
        // run, forever.
        expect(await fixture.accountBalance('payable:operator:$operatorId'), 0);
        expect(
          await fixture.accountBalance('cash:$operatorId:$stationId:till'),
          0,
        );
      },
    );

    test('what was sent, to whom and by whom is written down', () async {
      await fixture.railCapture(
        operatorId: operatorId,
        fareMinor: 50000,
        serviceFeeMinor: 300,
        commissionMinor: 2500,
      );
      final run = await prepared(window: 9);
      await payouts.approve(runId: run.id, actorUserId: approver);
      await payouts.release(
        runId: run.id,
        actorUserId: approver,
        reference: 'PAY-2026-33',
      );

      final entry = (await fixture.auditFor(operatorId)).singleWhere(
        (e) => e['action'] == 'payout.release' && e['subject_id'] == run.id,
      );
      expect(entry['after_state']['reference'], 'PAY-2026-33');
      expect(entry['after_state']['txnId'], isNotNull);
    });
  });

  group('who may see it', () {
    test('an operator reads their own statements', () async {
      await prepared(window: 10);

      final mine = await payouts.statementsFor(operatorId);
      expect(mine, isNotEmpty);
      // Newest first: the question is almost always about the last one.
      expect(
        mine.first.statement.to.isAfter(mine.last.statement.to) ||
            mine.length == 1,
        isTrue,
      );
    });

    test('the queue lists what is waiting, oldest first', () async {
      final pending = await payouts.pending(actorUserId: approver);

      expect(pending, isNotEmpty);
      for (final run in pending) {
        expect(run.isPending, isTrue);
      }
      for (var i = 1; i < pending.length; i++) {
        expect(
          pending[i].preparedAt.isBefore(pending[i - 1].preparedAt),
          isFalse,
        );
      }
    });
  });
}
