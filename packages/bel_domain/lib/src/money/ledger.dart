import '../shared/failure.dart';
import '../shared/result.dart';
import 'money.dart';

/// The chart of accounts (`04-payments.md` §2).
///
/// Account names are **strings on purpose**, built here and nowhere else. A
/// Dart enum cannot express `payable:operator:<id>` — one account per operator
/// — and a free-form string built at each call site is how a typo becomes a
/// balance nobody can explain three weeks later.
///
/// Every name is `nature:subject[:detail]`, so `account_balances` can be
/// grouped by prefix without a lookup table.
abstract final class LedgerAccount {
  /// Money a rail holds for us, not yet settled into the bank.
  static String pspClearing(String rail) => 'psp:$rail:clearing';

  /// Physical cash in a vendor's drawer. Scoped to the station, because a
  /// till is reconciled by the person who closes it and "the operator's cash"
  /// is not a thing anybody can count.
  static String till(String operatorId, String stationId) =>
      'cash:$operatorId:$stationId:till';

  static const bankOperating = 'bank:operating';

  /// What we owe an operator. At any instant this balance **is** the debt —
  /// nobody computes it and nobody can drift it.
  static String payableOperator(String operatorId) =>
      'payable:operator:$operatorId';

  static String payableRefund(String bookingId) => 'payable:refund:$bookingId';

  static const revenueCommission = 'revenue:commission';
  static const revenueServiceFee = 'revenue:service_fee';
  static const revenueRescheduleFee = 'revenue:reschedule_fee';
  static const expensePspFees = 'expense:psp_fees';

  /// Money we cannot yet attribute. Watched daily; an item older than 48 h is
  /// an alert, because a suspense account that grows is reconciliation
  /// quietly breaking down.
  static const suspenseUnreconciled = 'suspense:unreconciled';
}

enum LedgerDirection { debit, credit }

/// One side of one movement.
final class LedgerEntry {
  const LedgerEntry({
    required this.account,
    required this.direction,
    required this.amount,
    this.operatorId,
    this.memo,
  });

  const LedgerEntry.debit(
    String account,
    Money amount, {
    String? operatorId,
    String? memo,
  }) : this(
         account: account,
         direction: LedgerDirection.debit,
         amount: amount,
         operatorId: operatorId,
         memo: memo,
       );

  const LedgerEntry.credit(
    String account,
    Money amount, {
    String? operatorId,
    String? memo,
  }) : this(
         account: account,
         direction: LedgerDirection.credit,
         amount: amount,
         operatorId: operatorId,
         memo: memo,
       );

  final String account;
  final LedgerDirection direction;
  final Money amount;
  final String? operatorId;
  final String? memo;

  /// Positive for a debit, negative for a credit. Summing this across a
  /// transaction is the balance check, and it is the same expression the
  /// `ledger_txn_balances` view computes in SQL — deliberately, so a
  /// disagreement between Dart and Postgres is impossible rather than merely
  /// unlikely.
  int get signedMinor =>
      direction == LedgerDirection.debit ? amount.minor : -amount.minor;
}

final class UnbalancedTransaction extends DomainFailure {
  const UnbalancedTransaction(this.offByMinor);
  final int offByMinor;
  @override
  String get code => 'ledger.unbalanced';
  @override
  Map<String, Object?> get params => {'offBy': offByMinor};
  @override
  String toString() => 'UnbalancedTransaction(off by $offByMinor)';
}

final class MixedCurrencies extends DomainFailure {
  const MixedCurrencies();
  @override
  String get code => 'ledger.mixed_currencies';
}

/// A complete, balanced movement.
///
/// Constructed only through [balanced], which refuses anything that does not
/// sum to zero. The database refuses it too — `ledger_entries_must_balance` is
/// a deferred constraint trigger that fires at COMMIT — and that redundancy is
/// intentional: this one gives a caller a typed failure it can act on, and
/// that one guarantees no code path anywhere can write a half-entry.
final class LedgerTransaction {
  const LedgerTransaction._(this.entries);

  final List<LedgerEntry> entries;

  Money get total {
    var minor = 0;
    for (final e in entries) {
      if (e.direction == LedgerDirection.debit) minor += e.amount.minor;
    }
    return Money(minor, entries.first.amount.currency);
  }

  static Result<LedgerTransaction, DomainFailure> balanced(
    List<LedgerEntry> entries,
  ) {
    if (entries.length < 2) {
      return const Err(UnbalancedTransaction(0));
    }

    final currency = entries.first.amount.currency;
    var sum = 0;
    for (final entry in entries) {
      if (entry.amount.currency != currency)
        return const Err(MixedCurrencies());
      if (entry.amount.minor <= 0) {
        // The schema's CHECK says the same thing. A negative amount is always
        // a direction expressed twice, and it makes every balance query lie.
        return const Err(UnbalancedTransaction(0));
      }
      sum += entry.signedMinor;
    }

    if (sum != 0) return Err(UnbalancedTransaction(sum));
    return Ok(LedgerTransaction._(entries));
  }
}

/// The postings for one sale. Where the chart of accounts stops being a table
/// in a document and becomes code.
abstract final class Postings {
  /// A counter sale paid in cash (`04-payments.md` §4.4).
  ///
  /// ```
  /// DR  cash:<operator>:<station>:till     9 300
  ///     CR  payable:operator:<id>                  9 000
  ///     CR  revenue:service_fee                      300
  /// ```
  ///
  /// **Zero commission, by design** (product brief D-04). That is what gets
  /// the console installed, and the console is what gives us the data — so
  /// there is no commission row here and no parameter to accidentally set one.
  /// The operator holds the cash and owes us the service fee; the payout run
  /// nets the two, which is why this is a payable rather than a transfer.
  static Result<LedgerTransaction, DomainFailure> cashSale({
    required String operatorId,
    required String stationId,
    required Money fare,
    required Money serviceFee,
  }) {
    final total = fare + serviceFee;

    return LedgerTransaction.balanced([
      LedgerEntry.debit(
        LedgerAccount.till(operatorId, stationId),
        total,
        operatorId: operatorId,
        memo: 'cash sale',
      ),
      LedgerEntry.credit(
        LedgerAccount.payableOperator(operatorId),
        fare,
        operatorId: operatorId,
      ),
      // Dropped rather than posted as zero: a zero-amount row fails the
      // schema's positive-amount CHECK, and a fee-free market is a real
      // configuration rather than an edge case.
      if (serviceFee.minor > 0)
        LedgerEntry.credit(LedgerAccount.revenueServiceFee, serviceFee),
    ]);
  }

  /// Putting a missed passenger on a later coach, paid at the counter.
  ///
  /// ```
  /// DR  cash:<operator>:<station>:till     2 700
  ///     CR  payable:operator:<id>                  2 700
  /// ```
  ///
  /// The same shape as [cashSale] and deliberately **not** the same call: the
  /// memo is what somebody reads six weeks later when a passenger says they
  /// were charged twice, and "cash sale" against a booking that already has
  /// one is exactly the row that starts that argument.
  ///
  /// No service fee. We took ours when the seat was first sold, and taking a
  /// second one because somebody overslept would be charging a platform fee
  /// for a platform that did nothing — the fee here is the operator's, for
  /// holding a seat open on a coach they could have sold.
  static Result<LedgerTransaction, DomainFailure> missedTransfer({
    required String operatorId,
    required String stationId,
    required Money paid,
  }) => LedgerTransaction.balanced([
    LedgerEntry.debit(
      LedgerAccount.till(operatorId, stationId),
      paid,
      operatorId: operatorId,
      memo: 'missed departure transfer',
    ),
    LedgerEntry.credit(
      LedgerAccount.payableOperator(operatorId),
      paid,
      operatorId: operatorId,
    ),
  ]);

  /// Approving a refund: we stop owing the operator and start owing the
  /// traveller (`04-payments.md` §4.6).
  ///
  /// ```
  /// DR  payable:operator:<id>          8 100   (what comes out of their share)
  /// DR  revenue:service_fee              300   (only when the policy refunds it)
  ///     CR  payable:refund:<booking>           8 400
  /// ```
  ///
  /// **Nothing is reversed that the policy retained.** A 90% band leaves 10%
  /// credited to the operator exactly where it was, because they earned it
  /// under terms the traveller agreed to. Posting the whole sale back and then
  /// re-charging the retained share would be two lies that happen to cancel.
  ///
  /// The debt is to the **booking**, not to a person: a claim is collected by
  /// whoever holds the code, and the ledger should say what is owed rather
  /// than guess who will walk in.
  static Result<LedgerTransaction, DomainFailure> refundApproved({
    required String operatorId,
    required String bookingId,
    required Money fromOperator,
    required Money fromServiceFee,
  }) {
    final owed = fromOperator + fromServiceFee;
    if (owed.minor <= 0) return const Err(UnbalancedTransaction(0));

    return LedgerTransaction.balanced([
      if (fromOperator.minor > 0)
        LedgerEntry.debit(
          LedgerAccount.payableOperator(operatorId),
          fromOperator,
          operatorId: operatorId,
          memo: 'refund approved',
        ),
      // Our own revenue, given back, and only when the operator's policy says
      // so. Debiting a revenue account is how a refund of a fee is expressed;
      // there is no "negative revenue" row anywhere in this ledger.
      if (fromServiceFee.minor > 0)
        LedgerEntry.debit(LedgerAccount.revenueServiceFee, fromServiceFee),
      LedgerEntry.credit(
        LedgerAccount.payableRefund(bookingId),
        owed,
        operatorId: operatorId,
        memo: 'owed to traveller',
      ),
    ]);
  }

  /// Paying a refund claim out of the drawer (ADR-0015 rule 5).
  ///
  /// ```
  /// DR  payable:refund:<booking>       8 400
  ///     CR  cash:<operator>:<station>:till     8 400
  /// ```
  ///
  /// Scoped to the **station**, like the sale that filled the drawer, because
  /// a till is counted at the end of a shift by the person who closed it. A
  /// refund paid from "the operator's cash" is a number nobody can reconcile
  /// against anything they physically counted.
  static Result<LedgerTransaction, DomainFailure> refundPaidInCash({
    required String operatorId,
    required String stationId,
    required String bookingId,
    required Money amount,
  }) => LedgerTransaction.balanced([
    LedgerEntry.debit(
      LedgerAccount.payableRefund(bookingId),
      amount,
      operatorId: operatorId,
      memo: 'refund claimed',
    ),
    LedgerEntry.credit(
      LedgerAccount.till(operatorId, stationId),
      amount,
      operatorId: operatorId,
    ),
  ]);

  /// A digital capture on a mobile-money or card rail (`04-payments.md` §2).
  ///
  /// Commission is netted **at source** — the operator is credited the fare
  /// less our cut, rather than credited in full and invoiced later. An
  /// operator who has to be invoiced is an operator who eventually does not
  /// pay, and chasing that in Congo is not a business we are in.
  static Result<LedgerTransaction, DomainFailure> railCapture({
    required String operatorId,
    required String rail,
    required Money fare,
    required Money serviceFee,
    required Money commission,
  }) {
    final total = fare + serviceFee;
    final operatorShare = fare - commission;

    if (operatorShare.minor < 0) {
      return Err(UnbalancedTransaction(operatorShare.minor));
    }

    return LedgerTransaction.balanced([
      LedgerEntry.debit(
        LedgerAccount.pspClearing(rail),
        total,
        operatorId: operatorId,
        memo: 'capture on $rail',
      ),
      LedgerEntry.credit(
        LedgerAccount.payableOperator(operatorId),
        operatorShare,
        operatorId: operatorId,
      ),
      if (commission.minor > 0)
        LedgerEntry.credit(LedgerAccount.revenueCommission, commission),
      if (serviceFee.minor > 0)
        LedgerEntry.credit(LedgerAccount.revenueServiceFee, serviceFee),
    ]);
  }
}

/// Splits an amount across weights so the parts sum **exactly** to the whole.
///
/// Wraps `Money.allocate` with the naming the payments doc uses, because
/// "largest remainder" is the term an accountant will look for and
/// `allocate` is the term a programmer will. The property both care about is
/// the same one: no rounding dust is left in a suspense account.
List<Money> largestRemainder(Money amount, List<int> weights) =>
    amount.allocate(weights);
