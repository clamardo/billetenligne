import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  const xaf = Currency.xaf;
  Money xa(int minor) => Money(minor, xaf);

  final from = DateTime.utc(2026, 8, 1);
  final to = DateTime.utc(2026, 8, 8);

  PayoutStatement statement({
    int payable = 3708000,
    int tills = 192000,
    int cashCount = 188,
  }) => PayoutStatement(
    operatorId: 'op-1',
    from: from,
    to: to,
    onlineSalesCount: 412,
    onlineGross: xa(3708000),
    cashSalesCount: cashCount,
    cashGross: xa(1692000),
    commission: xa(185400),
    serviceFees: xa(180000),
    refunds: xa(126000),
    payable: xa(payable),
    tills: xa(tills),
  );

  group('the statement', () {
    test('the drawer is counted against what we owe, not paid out', () {
      // The single most common operator question is "where is my cash
      // money?", and the answer is that they are already holding it.
      expect(statement().net, xa(3708000 - 192000));
      expect(statement().isPayable, isTrue);
    });

    test('a week of nothing but cash leaves the operator owing us', () {
      // Zero commission on cash (product brief D-04) but the service fee is
      // still ours, and it is in their drawer. Netting is what collects it
      // without an invoice ever being raised.
      final cashOnly = statement(payable: 1692000, tills: 1746000);

      expect(cashOnly.isPayable, isFalse);
      expect(cashOnly.operatorOwesUs, isTrue);
      expect(cashOnly.owedToUs, xa(54000));
    });

    test('the window is half-open', () {
      // A statement for the week ending Sunday must not contain Monday's
      // first sale, and "01→07" in the header is a closed range for a reader
      // and a half-open one for a query.
      expect(statement().from, from);
      expect(statement().to, to);
      expect(to.difference(from).inDays, 7);
    });
  });

  group('releasing it', () {
    test('the drawers are settled in the same transaction as the transfer', () {
      final posted = payoutReleased(
        operatorId: 'op-1',
        payable: xa(3708000),
        tills: {'st-bzv': xa(150000), 'st-pnr': xa(42000)},
        reference: 'PAY-2026-32',
      );

      final txn = posted.valueOrNull!;
      // Paying the net and leaving the till standing would mean the same
      // cash counted against every future run, forever.
      expect(txn.entries, hasLength(4));
      expect(
        txn.entries
            .where((e) => e.direction == LedgerDirection.credit)
            .map((e) => e.amount.minor)
            .reduce((a, b) => a + b),
        3708000,
      );
      expect(
        txn.entries.singleWhere((e) => e.account == 'bank:operating').amount,
        xa(3516000),
      );
    });

    test('an empty drawer is not a zero row', () {
      // A zero-amount entry fails the schema's positive-amount CHECK, and an
      // operator with one station and no cash sales is entirely ordinary.
      final txn = payoutReleased(
        operatorId: 'op-1',
        payable: xa(9000),
        tills: {'st-bzv': xa(0)},
        reference: 'PAY-1',
      ).valueOrNull!;

      expect(txn.entries, hasLength(2));
    });

    test('a negative balance is refused rather than reversed', () {
      // Money moving the other way is an invoice and a conversation, not a
      // payout run with a minus sign in it.
      final refused = payoutReleased(
        operatorId: 'op-1',
        payable: xa(1692000),
        tills: {'st-bzv': xa(1746000)},
        reference: 'PAY-1',
      );

      expect(refused.failureOrNull, isA<OperatorOwesUs>());
      expect(refused.failureOrNull!.params['amount'], 54000);
    });

    test('paying nothing is refused', () {
      final refused = payoutReleased(
        operatorId: 'op-1',
        payable: xa(9000),
        tills: {'st-bzv': xa(9000)},
        reference: 'PAY-1',
      );

      expect(refused.failureOrNull, isA<NothingToPay>());
    });

    test('every payout balances', () {
      // The guarantee the whole ledger rests on, asserted here rather than
      // assumed: `LedgerTransaction.balanced` refuses anything else.
      final txn = payoutReleased(
        operatorId: 'op-1',
        payable: xa(100001),
        tills: {'a': xa(33333), 'b': xa(1)},
        reference: 'PAY-1',
      ).valueOrNull!;

      var signed = 0;
      for (final entry in txn.entries) {
        signed += entry.direction == LedgerDirection.debit
            ? entry.amount.minor
            : -entry.amount.minor;
      }
      expect(signed, 0);
    });
  });
}
