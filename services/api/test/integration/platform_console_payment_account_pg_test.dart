@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/operator_console.dart'
    show PaymentAccountSummary;
import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_platform_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Verifying an operator's mobile-money account, against a real database.
///
/// This is the only place `verified_at` gets written (`operator_console.dart`'s
/// `savePaymentAccount` doc-comment) — a manual back-office decision, not a
/// third-party call this deployment makes. The claims a Dart map cannot make:
/// that the SQL guard, not just the interface, refuses a second decision on
/// an account already decided (`illegalTransition`), and that every decision
/// leaves an audit row a platform user can be held to.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresPlatformConsole console;
  late String operatorId;
  late String actorUserId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresPlatformConsole(db, timeZone: PgFixture.timeZone);
    operatorId = PgFixture.operatorId;
    actorUserId = await fixture.traveller('platform1', name: 'Sarah N.');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;

  Future<String> freshAccount({bool verified = false}) async {
    // The unique index is on (operator_id, rail_id) WHERE active, and this
    // fixture's operator is shared across every test in this file (and,
    // between runs, across the same kept-alive container) — a rail_id has to
    // be unique across all of that, not just within one test.
    final unique = '${DateTime.now().microsecondsSinceEpoch}${++seq}';
    final rows = await fixture.rows('''
      INSERT INTO operator_payment_accounts
        (operator_id, rail_id, msisdn, display_name, verified_at, active)
      VALUES ('$operatorId', 'test.rail$unique', '242060${unique.substring(unique.length - 9)}',
              'Ocean du Nord', ${verified ? 'now()' : 'NULL'}, TRUE)
      RETURNING id
    ''');
    return rows.single['id'] as String;
  }

  test('verifying an unverified account writes verified_at', () async {
    final accountId = await freshAccount();

    final result = await console.decidePaymentAccount(
      operatorId: operatorId,
      accountId: accountId,
      decision: PaymentAccountDecision.verify,
      actorUserId: actorUserId,
      reason: 'accord marchand vu le 12/09',
    );

    expect(result, isA<Ok<PaymentAccountSummary, DecisionRefusal>>());
    final account =
        (result as Ok<PaymentAccountSummary, DecisionRefusal>).value;
    expect(account.verified, isTrue);
    expect(account.active, isTrue);

    final audit = await fixture.auditFor(operatorId);
    final row = audit.singleWhere(
      (r) =>
          r['action'] == 'payment_account.verify' &&
          r['subject_id'] == accountId,
    );
    expect(row['actor_id'].toString(), actorUserId);
    expect(row['reason'], 'accord marchand vu le 12/09');
    expect(row['before_state'], {'verified': false, 'active': true});
    expect(row['after_state'], {'verified': true, 'active': true});
  });

  test(
    'verifying an already-verified account is refused, not re-recorded',
    () async {
      final accountId = await freshAccount(verified: true);

      final result = await console.decidePaymentAccount(
        operatorId: operatorId,
        accountId: accountId,
        decision: PaymentAccountDecision.verify,
        actorUserId: actorUserId,
        reason: 'nouvelle tentative',
      );

      expect(
        result,
        const Err<PaymentAccountSummary, DecisionRefusal>(
          DecisionRefusal.illegalTransition,
        ),
      );
    },
  );

  test('rejecting deactivates rather than deletes', () async {
    final accountId = await freshAccount();

    final result = await console.decidePaymentAccount(
      operatorId: operatorId,
      accountId: accountId,
      decision: PaymentAccountDecision.reject,
      actorUserId: actorUserId,
      reason: 'numéro introuvable au contrôle',
    );

    expect(result, isA<Ok<PaymentAccountSummary, DecisionRefusal>>());
    final account =
        (result as Ok<PaymentAccountSummary, DecisionRefusal>).value;
    expect(account.active, isFalse);

    final rows = await fixture.rows('''
      SELECT active FROM operator_payment_accounts WHERE id = '$accountId'
    ''');
    expect(rows, hasLength(1));
    expect(rows.single['active'], isFalse);
  });

  test('rejecting an already-inactive account is refused', () async {
    final accountId = await freshAccount();
    await console.decidePaymentAccount(
      operatorId: operatorId,
      accountId: accountId,
      decision: PaymentAccountDecision.reject,
      actorUserId: actorUserId,
      reason: 'first rejection',
    );

    final second = await console.decidePaymentAccount(
      operatorId: operatorId,
      accountId: accountId,
      decision: PaymentAccountDecision.reject,
      actorUserId: actorUserId,
      reason: 'second rejection',
    );

    expect(
      second,
      const Err<PaymentAccountSummary, DecisionRefusal>(
        DecisionRefusal.illegalTransition,
      ),
    );
  });

  test('an unknown account id is refused, not a null crash', () async {
    final result = await console.decidePaymentAccount(
      operatorId: operatorId,
      accountId: '00000000-0000-0000-0000-000000000000',
      decision: PaymentAccountDecision.verify,
      actorUserId: actorUserId,
      reason: 'quelconque',
    );

    expect(
      result,
      const Err<PaymentAccountSummary, DecisionRefusal>(
        DecisionRefusal.unknownOperator,
      ),
    );
  });

  test('an account that belongs to a different operator is refused', () async {
    final otherRows = await fixture.rows('''
        INSERT INTO operators (code, legal_name, trading_name, status,
                               market_code)
        VALUES ('OTH-${DateTime.now().microsecondsSinceEpoch}',
                'Autre SARL', 'Autre', 'active', 'CG')
        RETURNING id
      ''');
    final otherOperatorId = otherRows.single['id'] as String;
    final accountId = await freshAccount();

    final result = await console.decidePaymentAccount(
      operatorId: otherOperatorId,
      accountId: accountId,
      decision: PaymentAccountDecision.verify,
      actorUserId: actorUserId,
      reason: 'wrong operator',
    );

    expect(
      result,
      const Err<PaymentAccountSummary, DecisionRefusal>(
        DecisionRefusal.unknownOperator,
      ),
    );
  });
}
