import '../shared/failure.dart';
import '../shared/result.dart';
import 'ledger.dart';
import 'money.dart';

/// What an operator is told, and what decides the transfer.
///
/// Two different things, and keeping them apart is the whole design of this
/// file:
///
///   * The **line items** are the period's activity — sales, commission,
///     refunds. They exist to be read and argued with. `04-payments.md` §6.2
///     shows the shape, and cash sales appear on it even though they never
///     generate a payout, because "where is my cash money?" is the single
///     most common operator question.
///   * The **amount** is the balance of `payable:operator:<id>` less whatever
///     is sitting in their tills, at the moment of the run. Not the sum of
///     the line items. A payout that summed a period would drift from the
///     ledger the first time anything landed a day late, and then two numbers
///     would both claim to be the debt.
final class PayoutStatement {
  const PayoutStatement({
    required this.operatorId,
    required this.from,
    required this.to,
    required this.onlineSalesCount,
    required this.onlineGross,
    required this.cashSalesCount,
    required this.cashGross,
    required this.commission,
    required this.serviceFees,
    required this.refunds,
    required this.payable,
    required this.tills,
  });

  final String operatorId;

  /// The reporting window, half-open: `[from, to)`. A statement for the week
  /// ending Sunday must not contain Monday's first sale.
  final DateTime from;
  final DateTime to;

  final int onlineSalesCount;

  /// Fares sold on a rail, before commission. Gross, because an operator
  /// checking a statement against their own count is counting tickets at the
  /// price on them.
  final Money onlineGross;

  final int cashSalesCount;
  final Money cashGross;

  /// Our cut of the online fares, already netted at source when each sale
  /// settled. Shown because it is deducted, not because it is deducted here.
  final Money commission;

  /// The traveller-paid fee on every sale, ours in both channels. On a cash
  /// sale this is the money the operator holds and owes us — which is why a
  /// week of nothing but cash sales produces a *negative* net.
  final Money serviceFees;

  final Money refunds;

  /// What the ledger says we owe, right now.
  final Money payable;

  /// What is sitting in this operator's drawers, right now.
  ///
  /// Counted **against** the payable rather than paid out: the operator is
  /// already holding that cash. Netting the two is what makes a cash sale
  /// cost them the service fee and nothing else, without an invoice ever
  /// being raised.
  final Money tills;

  Money get net => payable - tills;

  /// Whether anything actually moves. A week where an operator sold nothing
  /// online and took cash all week ends up negative — they owe us the fees —
  /// and that is a statement, not a transfer.
  bool get isPayable => net.minor > 0;

  bool get operatorOwesUs => net.minor < 0;

  /// What they owe, as a positive number, for an invoice that says so.
  Money get owedToUs => Money(-net.minor, net.currency);
}

/// A payout that would move money the wrong way.
final class OperatorOwesUs extends DomainFailure {
  const OperatorOwesUs(this.amountMinor);
  final int amountMinor;

  @override
  String get code => 'payout.operator_owes_us';

  @override
  Map<String, Object?> get params => {'amount': amountMinor};
}

/// A payout of nothing.
final class NothingToPay extends DomainFailure {
  const NothingToPay();

  @override
  String get code => 'payout.nothing_to_pay';
}

/// The postings for releasing a payout (`04-payments.md` §6.2).
///
/// ```
/// DR  payable:operator:<id>            3 429 600
///     CR  cash:<op>:<station>:till           192 000   (each drawer)
///     CR  bank:operating                   3 237 600
/// ```
///
/// **The drawers are settled in the same transaction as the transfer.** An
/// operator's till is an asset of theirs that we have been carrying against
/// what we owe them; clearing it here is what makes "cash sales never
/// generate a payout" true in the ledger rather than only in the statement.
/// Paying the net while leaving the till standing would mean the same cash
/// counted against every future run, forever.
Result<LedgerTransaction, DomainFailure> payoutReleased({
  required String operatorId,
  required Money payable,
  required Map<String, Money> tills,
  required String reference,
}) {
  final held = tills.values.fold(
    Money(0, payable.currency),
    (total, amount) => total + amount,
  );
  final net = payable - held;

  if (net.minor < 0) return Err(OperatorOwesUs(-net.minor));
  if (net.minor == 0) return const Err(NothingToPay());

  return LedgerTransaction.balanced([
    LedgerEntry.debit(
      LedgerAccount.payableOperator(operatorId),
      payable,
      operatorId: operatorId,
      memo: 'payout $reference',
    ),
    for (final entry in tills.entries)
      if (entry.value.minor > 0)
        LedgerEntry.credit(
          LedgerAccount.till(operatorId, entry.key),
          entry.value,
          operatorId: operatorId,
          memo: 'drawer settled',
        ),
    LedgerEntry.credit(
      LedgerAccount.bankOperating,
      net,
      operatorId: operatorId,
      memo: 'payout $reference',
    ),
  ]);
}
