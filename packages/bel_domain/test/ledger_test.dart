import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

Money xaf(int minor) => Money(minor, Currency.xaf);

int balanceOf(LedgerTransaction txn) =>
    txn.entries.fold(0, (sum, e) => sum + e.signedMinor);

void main() {
  _refundPostings();
  group('the balance invariant', () {
    test('a balanced transaction is accepted', () {
      final result = LedgerTransaction.balanced([
        LedgerEntry.debit(LedgerAccount.bankOperating, xaf(9300)),
        LedgerEntry.credit(LedgerAccount.revenueServiceFee, xaf(300)),
        LedgerEntry.credit(LedgerAccount.payableOperator('ODN'), xaf(9000)),
      ]);

      expect(result.isOk, isTrue);
      expect(balanceOf(result.valueOrNull!), 0);
    });

    test('an unbalanced one is refused, and says by how much', () {
      final result = LedgerTransaction.balanced([
        LedgerEntry.debit(LedgerAccount.bankOperating, xaf(9300)),
        LedgerEntry.credit(LedgerAccount.payableOperator('ODN'), xaf(9000)),
      ]);

      final failure = result.failureOrNull! as UnbalancedTransaction;
      expect(failure.offByMinor, 300);
      // The database refuses it too, at COMMIT. The redundancy is the point:
      // this one gives a caller something typed to act on, and that one
      // guarantees no path anywhere can write a half-entry.
      expect(failure.code, 'ledger.unbalanced');
    });

    test('a single entry is never a transaction', () {
      final result = LedgerTransaction.balanced([
        LedgerEntry.debit(LedgerAccount.bankOperating, xaf(9300)),
      ]);
      expect(result.isErr, isTrue);
    });

    test('a negative amount is refused rather than flipped', () {
      // A negative amount is always a direction expressed twice, and it makes
      // every balance query lie. The schema's CHECK says the same thing.
      final result = LedgerTransaction.balanced([
        LedgerEntry.debit(LedgerAccount.bankOperating, xaf(-9300)),
        LedgerEntry.credit(LedgerAccount.payableOperator('ODN'), xaf(-9300)),
      ]);
      expect(result.isErr, isTrue);
    });

    test('two currencies in one movement is refused', () {
      final result = LedgerTransaction.balanced([
        LedgerEntry.debit(LedgerAccount.bankOperating, xaf(9300)),
        LedgerEntry.credit(
          LedgerAccount.payableOperator('ODN'),
          const Money(9300, Currency.cdf),
        ),
      ]);
      expect(result.failureOrNull, isA<MixedCurrencies>());
    });
  });

  group('a cash counter sale', () {
    test('posts the worked example from 04-payments', () {
      final txn = Postings.cashSale(
        operatorId: 'ODN',
        stationId: 'BZV',
        fare: xaf(9000),
        serviceFee: xaf(300),
      ).valueOrNull!;

      expect(balanceOf(txn), 0);
      expect(txn.total, xaf(9300));

      final byAccount = {for (final e in txn.entries) e.account: e};
      expect(byAccount['cash:ODN:BZV:till']!.direction, LedgerDirection.debit);
      expect(byAccount['cash:ODN:BZV:till']!.amount, xaf(9300));
      expect(byAccount['payable:operator:ODN']!.amount, xaf(9000));
      expect(byAccount['revenue:service_fee']!.amount, xaf(300));
    });

    test('carries zero commission, and has no way to carry any', () {
      // Product brief D-04. That is what gets the console installed, and the
      // console is what gives us the data — so there is no commission row and
      // no parameter that could accidentally set one.
      final txn = Postings.cashSale(
        operatorId: 'ODN',
        stationId: 'BZV',
        fare: xaf(9000),
        serviceFee: xaf(300),
      ).valueOrNull!;

      expect(
        txn.entries.map((e) => e.account),
        isNot(contains(LedgerAccount.revenueCommission)),
      );
    });

    test('a fee-free market posts two rows, not a zero one', () {
      // A zero-amount row fails the schema's positive-amount CHECK, and a
      // market with no service fee is a real configuration.
      final txn = Postings.cashSale(
        operatorId: 'ODN',
        stationId: 'BZV',
        fare: xaf(9000),
        serviceFee: xaf(0),
      ).valueOrNull!;

      expect(txn.entries, hasLength(2));
      expect(balanceOf(txn), 0);
    });

    test('the till is scoped to a station, because a person closes it', () {
      final txn = Postings.cashSale(
        operatorId: 'ODN',
        stationId: 'PNR',
        fare: xaf(9000),
        serviceFee: xaf(300),
      ).valueOrNull!;

      // "The operator's cash" is not a thing anybody can count. A drawer in
      // Pointe-Noire is.
      expect(
        txn.entries.first.account,
        isNot(contains(LedgerAccount.till('ODN', 'BZV'))),
      );
      expect(txn.entries.first.account, 'cash:ODN:PNR:till');
    });
  });

  group('a rail capture', () {
    test('nets commission at source', () {
      final txn = Postings.railCapture(
        operatorId: 'ODN',
        rail: 'airtel',
        fare: xaf(9000),
        serviceFee: xaf(300),
        commission: xaf(450),
      ).valueOrNull!;

      expect(balanceOf(txn), 0);

      final byAccount = {for (final e in txn.entries) e.account: e};
      expect(byAccount['psp:airtel:clearing']!.amount, xaf(9300));
      // Credited the fare LESS our cut, not credited in full and invoiced.
      // An operator who has to be invoiced is one who eventually does not pay.
      expect(byAccount['payable:operator:ODN']!.amount, xaf(8550));
      expect(byAccount['revenue:commission']!.amount, xaf(450));
      expect(byAccount['revenue:service_fee']!.amount, xaf(300));
    });

    test('commission larger than the fare is refused, not netted negative', () {
      final result = Postings.railCapture(
        operatorId: 'ODN',
        rail: 'airtel',
        fare: xaf(1000),
        serviceFee: xaf(300),
        commission: xaf(1500),
      );
      expect(result.isErr, isTrue);
    });
  });

  group('largest remainder', () {
    test('splits sum exactly to the original', () {
      // The property that matters: no rounding dust left in a suspense
      // account, ever, for any weights.
      for (final total in [9300, 1, 7, 10001, 999999]) {
        for (final weights in [
          [1, 1, 1],
          [95, 5],
          [1, 2, 3, 4],
          [7],
        ]) {
          final parts = largestRemainder(xaf(total), weights);
          expect(
            parts.fold(0, (s, m) => s + m.minor),
            total,
            reason: 'total=$total weights=$weights',
          );
        }
      }
    });

    test('a three-way split of an indivisible amount loses nothing', () {
      final parts = largestRemainder(xaf(10), [1, 1, 1]);
      expect(parts.map((m) => m.minor).toList(), [4, 3, 3]);
    });
  });

  test('account names are built in one place', () {
    // A free-form string at each call site is how a typo becomes a balance
    // nobody can explain three weeks later.
    expect(LedgerAccount.pspClearing('airtel'), 'psp:airtel:clearing');
    expect(LedgerAccount.payableOperator('ODN'), 'payable:operator:ODN');
    expect(LedgerAccount.payableRefund('bk-1'), 'payable:refund:bk-1');
    expect(LedgerAccount.suspenseUnreconciled, 'suspense:unreconciled');
  });
}

/// The two movements a cash refund is made of.
void _refundPostings() {
  group('a refund moves a debt, it does not undo a sale', () {
    test('approval takes only what the policy actually gives back', () {
      // A 90% band on a 9 000 fare with a 300 fee the operator keeps.
      final txn = Postings.refundApproved(
        operatorId: 'op-1',
        bookingId: 'b-1',
        fromOperator: const Money.xaf(8100),
        fromServiceFee: const Money.xaf(0),
      );

      final entries = txn.valueOrNull!.entries;
      expect(entries, hasLength(2));
      // The retained 900 stays credited to the operator exactly where it was.
      // Posting the whole sale back and re-charging the retained share would
      // be two lies that happen to cancel.
      expect(
        entries.firstWhere((e) => e.direction == LedgerDirection.debit).amount,
        const Money.xaf(8100),
      );
      expect(
        entries
            .firstWhere((e) => e.direction == LedgerDirection.credit)
            .account,
        'payable:refund:b-1',
      );
    });

    test('a refunded service fee is a debit to our own revenue', () {
      final entries = Postings.refundApproved(
        operatorId: 'op-1',
        bookingId: 'b-1',
        fromOperator: const Money.xaf(9000),
        fromServiceFee: const Money.xaf(300),
      ).valueOrNull!.entries;

      // There is no negative-revenue row anywhere in this ledger: giving back
      // a fee is a debit to the account that earned it.
      final fee = entries.firstWhere((e) => e.account == 'revenue:service_fee');
      expect(fee.direction, LedgerDirection.debit);
      expect(fee.amount, const Money.xaf(300));
      expect(
        entries.firstWhere((e) => e.account == 'payable:refund:b-1').amount,
        const Money.xaf(9300),
      );
    });

    test('a refund of nothing is not a transaction', () {
      // The strict policy inside its no-refund window. Writing a zero-amount
      // pair would fail the schema's positive-amount CHECK and mean nothing.
      expect(
        Postings.refundApproved(
          operatorId: 'op-1',
          bookingId: 'b-1',
          fromOperator: const Money.xaf(0),
          fromServiceFee: const Money.xaf(0),
        ).isOk,
        isFalse,
      );
    });

    test('paying the claim empties the till, not the operator', () {
      final entries = Postings.refundPaidInCash(
        operatorId: 'op-1',
        stationId: 'st-bzv',
        bookingId: 'b-1',
        amount: const Money.xaf(8100),
      ).valueOrNull!.entries;

      // Scoped to the station, like the sale that filled the drawer: a till is
      // counted at the end of a shift by the person who closed it.
      expect(
        entries
            .firstWhere((e) => e.direction == LedgerDirection.credit)
            .account,
        'cash:op-1:st-bzv:till',
      );
      expect(
        entries.firstWhere((e) => e.direction == LedgerDirection.debit).account,
        'payable:refund:b-1',
      );
    });

    test('sending it down the rail empties a float, not a till', () {
      final entries = Postings.refundDisbursed(
        operatorId: 'op-1',
        bookingId: 'b-1',
        rail: 'cg.mtn_momo',
        amount: const Money.xaf(8400),
      ).valueOrNull!.entries;

      // **Not `psp:<rail>:clearing`.** Every mobile-money operator funds
      // payouts separately from what it collects, so netting a refund against
      // the day's takings would describe a movement that did not happen and
      // hide the one that did — the float going down, which is the number
      // somebody has to watch to know when to top it up.
      expect(
        entries
            .firstWhere((e) => e.direction == LedgerDirection.credit)
            .account,
        'psp:cg.mtn_momo:disbursement',
      );
      expect(
        entries.firstWhere((e) => e.direction == LedgerDirection.debit).account,
        'payable:refund:b-1',
      );
    });

    test('approve then send leaves the refund debt at zero, too', () {
      // The same property as the counter path, across the other pair. Both
      // ways of paying somebody back must extinguish exactly what was raised.
      final approved = Postings.refundApproved(
        operatorId: 'op-1',
        bookingId: 'b-1',
        fromOperator: const Money.xaf(8100),
        fromServiceFee: const Money.xaf(300),
      ).valueOrNull!;
      final sent = Postings.refundDisbursed(
        operatorId: 'op-1',
        bookingId: 'b-1',
        rail: 'cg.airtel_money',
        amount: const Money.xaf(8400),
      ).valueOrNull!;

      var balance = 0;
      for (final entry in [...approved.entries, ...sent.entries]) {
        if (entry.account == 'payable:refund:b-1') balance += entry.signedMinor;
      }
      expect(balance, 0);
    });

    test('approve then claim leaves the refund debt at zero', () {
      // The property that matters across the pair: what we owe the traveller
      // is created and extinguished exactly, with nothing stranded.
      final approved = Postings.refundApproved(
        operatorId: 'op-1',
        bookingId: 'b-1',
        fromOperator: const Money.xaf(8100),
        fromServiceFee: const Money.xaf(300),
      ).valueOrNull!;
      final paid = Postings.refundPaidInCash(
        operatorId: 'op-1',
        stationId: 'st-bzv',
        bookingId: 'b-1',
        amount: const Money.xaf(8400),
      ).valueOrNull!;

      var balance = 0;
      for (final entry in [...approved.entries, ...paid.entries]) {
        if (entry.account == 'payable:refund:b-1') balance += entry.signedMinor;
      }
      expect(balance, 0);
    });
  });
}
