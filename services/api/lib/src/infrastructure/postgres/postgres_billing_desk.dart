import 'package:bel_api/src/application/ports/billing_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

/// The platform subscription fee against Postgres (`04-payments.md` §6.2
/// note).
///
/// Every method runs on the **tenant** scope. Unlike a payout, there is
/// nothing here a platform back office needs to prepare or approve yet — one
/// flat tier, billed to whoever asks — so 0047 gives `bel_app` its own read
/// and its own get-or-create INSERT, and no UPDATE on the charge at all:
/// marking one paid is a back-office confirmation that ships with whichever
/// rail can first actually receive money, not before.
final class PostgresBillingDesk implements BillingDesk {
  const PostgresBillingDesk(
    this._db, {
    required this.monthlyFee,
    required this.timeZone,
  });

  final Database _db;

  /// One flat tier at launch — there is no plan to choose between, so this
  /// is a single configured amount rather than a table of them.
  final Money monthlyFee;

  /// IANA zone this operator's calendar month is drawn in, like
  /// `PostgresOperatorConsole`'s. A month boundary computed in UTC would
  /// occasionally bill the wrong eight hours to the wrong month.
  final String timeZone;

  @override
  Future<SubscriptionCharge> currentCharge(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final period = await tx.execute(
          Sql.named('''
            SELECT date_trunc('month', now() AT TIME ZONE @tz)::date
                     AS period_start,
                   (date_trunc('month', now() AT TIME ZONE @tz)
                     + interval '1 month')::date AS period_end
          '''),
          parameters: {'tz': TypedValue(Type.text, timeZone)},
        );
        final periodRow = period.first.toColumnMap();
        final periodStart = periodRow['period_start'] as DateTime;
        final periodEnd = periodRow['period_end'] as DateTime;

        // The get-or-create. `ON CONFLICT DO NOTHING` rather than
        // check-then-insert: two requests for the same new month racing each
        // other must create exactly one charge, not one each.
        final inserted = await tx.execute(
          Sql.named('''
            INSERT INTO platform_subscription_charges
              (operator_id, period_start, period_end, amount_minor, currency)
            VALUES (@operator, @start, @end, @amount, @currency)
            ON CONFLICT (operator_id, period_start) DO NOTHING
            RETURNING id, operator_id, period_start, period_end, amount_minor,
                      currency, status, created_at, paid_at
          '''),
          parameters: {
            'operator': TypedValue(Type.uuid, operatorId),
            'start': TypedValue(Type.date, periodStart),
            'end': TypedValue(Type.date, periodEnd),
            'amount': TypedValue(Type.bigInteger, monthlyFee.minor),
            'currency': TypedValue(Type.text, monthlyFee.currency.code),
          },
        );

        if (inserted.isNotEmpty) {
          await _postAccrual(
            tx,
            operatorId: operatorId,
            amount: monthlyFee,
            periodStart: periodStart,
          );
          return _hydrate(inserted.first.toColumnMap());
        }

        final existing = await tx.execute(
          Sql.named('''
            SELECT id, operator_id, period_start, period_end, amount_minor,
                   currency, status, created_at, paid_at
              FROM platform_subscription_charges
             WHERE operator_id = @operator AND period_start = @start
          '''),
          parameters: {
            'operator': TypedValue(Type.uuid, operatorId),
            'start': TypedValue(Type.date, periodStart),
          },
        );
        return _hydrate(existing.first.toColumnMap());
      });

  Future<void> _postAccrual(
    TxSession tx, {
    required String operatorId,
    required Money amount,
    required DateTime periodStart,
  }) async {
    final posting = Postings.subscriptionAccrued(
      operatorId: operatorId,
      amount: amount,
      memo:
          'platform fee ${periodStart.year}-'
          '${periodStart.month.toString().padLeft(2, '0')}',
    ).valueOrNull;
    // Unreachable in practice — the two entries this always builds are
    // always balanced — but `Postings.subscriptionAccrued` returns a
    // `Result` like every other posting in this file's family, and silently
    // skipping a failed one would post a charge with no ledger entry behind
    // it rather than surface the bug.
    if (posting == null) return;

    final generated = await tx.execute('SELECT gen_random_uuid() AS id');
    final txnId = generated.first.toColumnMap()['id'].toString();

    for (final entry in posting.entries) {
      await tx.execute(
        Sql.named('''
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency, operator_id,
             memo)
          VALUES (@txn, @account, @direction::ledger_direction, @amount,
                  @currency, @operator, @memo)
        '''),
        parameters: {
          'txn': TypedValue(Type.uuid, txnId),
          'account': TypedValue(Type.text, entry.account),
          'direction': TypedValue(Type.text, entry.direction.name),
          'amount': TypedValue(Type.bigInteger, entry.amount.minor),
          'currency': TypedValue(Type.text, entry.amount.currency.code),
          'operator': TypedValue(Type.uuid, entry.operatorId ?? operatorId),
          'memo': TypedValue(Type.text, entry.memo),
        },
        ignoreRows: true,
      );
    }
  }

  @override
  Future<String> paymentType(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT payment_type FROM platform_billing_accounts
             WHERE operator_id = @operator
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );
        return rows.isEmpty
            ? 'bank_transfer'
            : rows.first.toColumnMap()['payment_type'] as String;
      });

  @override
  Future<Result<void, BillingRefusal>> setPaymentType({
    required String operatorId,
    required String paymentType,
    required String actorUserId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    if (paymentType != 'card' && paymentType != 'bank_transfer') {
      return Err(UnknownPaymentType(paymentType));
    }

    await tx.execute(
      Sql.named('''
        INSERT INTO platform_billing_accounts
          (operator_id, payment_type, updated_by)
        VALUES (@operator, @type, @actor)
        ON CONFLICT (operator_id) DO UPDATE
          SET payment_type = EXCLUDED.payment_type,
              updated_by = EXCLUDED.updated_by,
              updated_at = now()
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'type': TypedValue(Type.text, paymentType),
        'actor': TypedValue(Type.uuid, actorUserId),
      },
      ignoreRows: true,
    );

    return const Ok(null);
  });

  static SubscriptionCharge _hydrate(Map<String, dynamic> row) =>
      SubscriptionCharge(
        id: row['id'].toString(),
        operatorId: row['operator_id'].toString(),
        periodStart: (row['period_start'] as DateTime).toUtc(),
        periodEnd: (row['period_end'] as DateTime).toUtc(),
        amount: Money(
          row['amount_minor'] as int,
          Currency.byCode(row['currency'] as String)!,
        ),
        status: row['status'] as String,
        createdAt: (row['created_at'] as DateTime).toUtc(),
        paidAt: (row['paid_at'] as DateTime?)?.toUtc(),
      );
}
