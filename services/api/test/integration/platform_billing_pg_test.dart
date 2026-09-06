@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/billing_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_billing_desk.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The platform subscription fee against a real database
/// (`04-payments.md` §6.2 note).
///
/// The unit-level design (in `packages/bel_platform/test/ledger_test.dart`)
/// proves the posting balances. What only a real database can prove: that
/// `bel_app` actually holds the grants migration 0047 claims — the exact bug
/// wallet verification shipped with (a table RLS called safe that `bel_app`
/// could not reach at all) — that the get-or-create is race-safe under the
/// real unique constraint rather than a mocked one, and that a second ask for
/// the same month never posts a second accrual.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresBillingDesk billing;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    billing = PostgresBillingDesk(
      db,
      monthlyFee: Money(25000, Currency.xaf),
      timeZone: PgFixture.timeZone,
    );
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A fresh operator per test, like the mobile-money fixture does — the
  /// unique index is `(operator_id, period_start)`, and every test in this
  /// file asks for "this calendar month", so two tests sharing one operator
  /// would race each other's get-or-create.
  var seq = 0;
  Future<String> freshOperator() async {
    final unique = '${DateTime.now().microsecondsSinceEpoch}${++seq}';
    final rows = await fixture.rows('''
      INSERT INTO operators (code, legal_name, trading_name, status,
                             market_code)
      VALUES ('BIL$unique', 'Facturée $unique SARL', 'Facturée $unique',
              'active', 'CG')
      RETURNING id
    ''');
    return rows.single['id'] as String;
  }

  test('the first ask this month creates the charge and its accrual', () async {
    final operatorId = await freshOperator();

    final charge = await billing.currentCharge(operatorId);

    expect(charge.operatorId, operatorId);
    expect(charge.status, 'due');
    expect(charge.amount, Money(25000, Currency.xaf));
    expect(charge.periodEnd.isAfter(charge.periodStart), isTrue);

    final entries = await fixture.rows('''
        SELECT account, direction::text AS direction, amount_minor, currency
          FROM ledger_entries
         WHERE operator_id = '$operatorId'
         ORDER BY account
      ''');
    expect(entries, hasLength(2));

    final byAccount = {for (final e in entries) e['account'] as String: e};
    expect(byAccount['receivable:operator:$operatorId']!['direction'], 'debit');
    expect(
      byAccount['receivable:operator:$operatorId']!['amount_minor'],
      25000,
    );
    expect(byAccount['revenue:subscription']!['direction'], 'credit');
    expect(byAccount['revenue:subscription']!['amount_minor'], 25000);

    final balance = await fixture.rows('''
        SELECT count(*)::int AS n FROM ledger_txn_balances
         WHERE balance_minor <> 0
      ''');
    expect(balance.single['n'], 0);
  });

  test(
    'a second ask the same month returns the same charge, and accrues nothing '
    'twice',
    () async {
      final operatorId = await freshOperator();

      final first = await billing.currentCharge(operatorId);
      final second = await billing.currentCharge(operatorId);

      expect(second.id, first.id);
      expect(second.periodStart, first.periodStart);

      final rows = await fixture.rows('''
        SELECT count(*)::int AS n FROM platform_subscription_charges
         WHERE operator_id = '$operatorId'
      ''');
      expect(rows.single['n'], 1);

      final entries = await fixture.rows('''
        SELECT count(*)::int AS n FROM ledger_entries
         WHERE operator_id = '$operatorId'
      ''');
      expect(entries.single['n'], 2);
    },
  );

  test(
    'the payment type defaults to bank transfer until an operator chooses',
    () async {
      final operatorId = await freshOperator();

      expect(await billing.paymentType(operatorId), 'bank_transfer');
    },
  );

  test('an operator can switch to card and back', () async {
    final operatorId = await freshOperator();
    final actorUserId = await fixture.traveller(
      'billing${DateTime.now().microsecondsSinceEpoch}',
    );

    final toCard = await billing.setPaymentType(
      operatorId: operatorId,
      paymentType: 'card',
      actorUserId: actorUserId,
    );
    expect(toCard, const Ok<void, BillingRefusal>(null));
    expect(await billing.paymentType(operatorId), 'card');

    final back = await billing.setPaymentType(
      operatorId: operatorId,
      paymentType: 'bank_transfer',
      actorUserId: actorUserId,
    );
    expect(back, const Ok<void, BillingRefusal>(null));
    expect(await billing.paymentType(operatorId), 'bank_transfer');
  });

  test('an unknown payment type is refused, and changes nothing', () async {
    final operatorId = await freshOperator();
    final actorUserId = await fixture.traveller(
      'billing${DateTime.now().microsecondsSinceEpoch}',
    );

    final result = await billing.setPaymentType(
      operatorId: operatorId,
      paymentType: 'crypto',
      actorUserId: actorUserId,
    );

    expect(result.isErr, isTrue);
    final refusal = result.failureOrNull;
    expect(refusal, isA<UnknownPaymentType>());
    expect((refusal! as UnknownPaymentType).paymentType, 'crypto');
    expect(await billing.paymentType(operatorId), 'bank_transfer');
  });
}
