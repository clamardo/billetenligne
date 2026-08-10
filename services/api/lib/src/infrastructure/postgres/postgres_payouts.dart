import 'package:bel_api/src/application/ports/payout_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

/// The payout run against Postgres (`04-payments.md` §6.2).
///
/// Every method here runs on the **platform** scope. That is not a
/// convenience: 0018 gives `bel_app` SELECT on `payout_runs` and nothing
/// else, so an operator connection physically cannot write one. Two-person
/// control on money leaving is worth nothing if the party being paid can move
/// the row that pays them.
final class PostgresPayouts implements PayoutDesk {
  const PostgresPayouts(this._db);

  final Database _db;

  @override
  Future<Result<PayoutRun, PayoutRefusal>> prepare({
    required String operatorId,
    required DateTime from,
    required DateTime to,
    required String actorUserId,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final operator = await tx.execute(
      Sql.named('''
        SELECT COALESCE(trading_name, legal_name) AS name,
               settlement_account_id::text AS settlement_account
          FROM operators WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    if (operator.isEmpty) return const Err(UnknownPayout());

    final clash = await tx.execute(
      Sql.named('''
        SELECT id FROM payout_runs
         WHERE operator_id = @operator AND period_start = @from
           AND period_end = @to AND state <> 'void'
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.timestampWithTimezone, from),
        'to': TypedValue(Type.timestampWithTimezone, to),
      },
    );
    if (clash.isNotEmpty) return const Err(PeriodAlreadyRun());

    // What the period contained, from the bookings themselves rather than
    // from the ledger: an operator checking this against their own count is
    // counting tickets at the price printed on them.
    final sales = await tx.execute(
      Sql.named('''
        SELECT
          count(*) FILTER (WHERE payment_method <> 'cash')::int
            AS online_count,
          COALESCE(sum(fare_minor) FILTER (WHERE payment_method <> 'cash'), 0)
            AS online_gross,
          count(*) FILTER (WHERE payment_method = 'cash')::int AS cash_count,
          COALESCE(sum(fare_minor) FILTER (WHERE payment_method = 'cash'), 0)
            AS cash_gross,
          COALESCE(sum(service_fee_minor), 0) AS service_fees
          FROM bookings
         WHERE operator_id = @operator
           AND paid_at >= @from AND paid_at < @to
           AND state IN ('confirmed', 'cancelled')
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.timestampWithTimezone, from),
        'to': TypedValue(Type.timestampWithTimezone, to),
      },
    );
    final period = sales.first.toColumnMap();

    // Our cut, as the ledger recorded it when each sale settled. Read from
    // the entries rather than recomputed from a rate: the rate is a term of
    // one contract and it can change mid-week.
    final commission = await tx.execute(
      Sql.named('''
        SELECT COALESCE(sum(
                 CASE WHEN direction = 'credit' THEN amount_minor
                      ELSE -amount_minor END), 0) AS total
          FROM ledger_entries
         WHERE operator_id = @operator AND account = @account
           AND created_at >= @from AND created_at < @to
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'account': TypedValue(Type.text, LedgerAccount.revenueCommission),
        'from': TypedValue(Type.timestampWithTimezone, from),
        'to': TypedValue(Type.timestampWithTimezone, to),
      },
    );

    final refunds = await tx.execute(
      Sql.named('''
        SELECT COALESCE(sum(amount_minor), 0) AS total
          FROM refunds
         WHERE operator_id = @operator
           AND state IN ('approved', 'processing', 'completed',
                         'claim_issued', 'claimed')
           AND created_at >= @from AND created_at < @to
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.timestampWithTimezone, from),
        'to': TypedValue(Type.timestampWithTimezone, to),
      },
    );

    final balances = await _balances(tx, operatorId);

    final statement = PayoutStatement(
      operatorId: operatorId,
      from: from,
      to: to,
      onlineSalesCount: period['online_count'] as int,
      onlineGross: _xaf(period['online_gross']),
      cashSalesCount: period['cash_count'] as int,
      cashGross: _xaf(period['cash_gross']),
      commission: _xaf(commission.first.toColumnMap()['total']),
      serviceFees: _xaf(period['service_fees']),
      refunds: _xaf(refunds.first.toColumnMap()['total']),
      payable: balances.payable,
      tills: balances.tills,
    );

    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO payout_runs
          (operator_id, period_start, period_end, currency,
           online_sales_count, online_gross_minor,
           cash_sales_count, cash_gross_minor,
           commission_minor, service_fees_minor, refunds_minor,
           payable_minor, tills_minor, net_minor,
           destination, prepared_by)
        VALUES (@operator, @from, @to, @currency,
                @onlineCount, @onlineGross, @cashCount, @cashGross,
                @commission, @fees, @refunds,
                @payable, @tills, @net, @destination, @actor)
        RETURNING id, prepared_at
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.timestampWithTimezone, from),
        'to': TypedValue(Type.timestampWithTimezone, to),
        'currency': TypedValue(Type.text, statement.payable.currency.code),
        'onlineCount': TypedValue(Type.integer, statement.onlineSalesCount),
        'onlineGross': TypedValue(Type.bigInteger, statement.onlineGross.minor),
        'cashCount': TypedValue(Type.integer, statement.cashSalesCount),
        'cashGross': TypedValue(Type.bigInteger, statement.cashGross.minor),
        'commission': TypedValue(Type.bigInteger, statement.commission.minor),
        'fees': TypedValue(Type.bigInteger, statement.serviceFees.minor),
        'refunds': TypedValue(Type.bigInteger, statement.refunds.minor),
        'payable': TypedValue(Type.bigInteger, statement.payable.minor),
        'tills': TypedValue(Type.bigInteger, statement.tills.minor),
        'net': TypedValue(Type.bigInteger, statement.net.minor),
        'destination': TypedValue(
          Type.text,
          operator.first.toColumnMap()['settlement_account'] as String?,
        ),
        'actor': TypedValue(Type.uuid, actorUserId),
      },
    );

    final row = inserted.first.toColumnMap();
    await _audit(
      tx,
      actorUserId: actorUserId,
      operatorId: operatorId,
      action: 'payout.prepare',
      runId: row['id'].toString(),
      after: {
        'net': statement.net.minor,
        'payable': statement.payable.minor,
        'tills': statement.tills.minor,
      },
    );

    return Ok(
      PayoutRun(
        id: row['id'].toString(),
        statement: statement,
        state: 'draft',
        preparedAt: row['prepared_at'] as DateTime,
        operatorName: operator.first.toColumnMap()['name'] as String?,
        destination:
            operator.first.toColumnMap()['settlement_account'] as String?,
      ),
    );
  });

  @override
  Future<Result<PayoutRun, PayoutRefusal>> approve({
    required String runId,
    required String actorUserId,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final found = await tx.execute(
      Sql.named('''
        SELECT state::text AS state, prepared_by
          FROM payout_runs WHERE id = @id FOR UPDATE
      '''),
      parameters: {'id': TypedValue(Type.uuid, runId)},
    );
    if (found.isEmpty) return const Err(UnknownPayout());

    final row = found.first.toColumnMap();
    if (row['state'] != 'draft') {
      return Err(WrongPayoutState(row['state'] as String));
    }

    // Two people, not two roles. One super-admin pressing both buttons is a
    // formality, and the whole reason this control exists is that a payout is
    // the largest single movement of money this platform makes.
    if (row['prepared_by']?.toString() == actorUserId) {
      return const Err(NeedsASecondPerson());
    }

    await tx.execute(
      Sql.named('''
        UPDATE payout_runs
           SET state = 'approved', approved_by = @actor, approved_at = now()
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, runId),
        'actor': TypedValue(Type.uuid, actorUserId),
      },
      ignoreRows: true,
    );

    final run = (await _read(tx, runId))!;
    await _audit(
      tx,
      actorUserId: actorUserId,
      operatorId: run.statement.operatorId,
      action: 'payout.approve',
      runId: runId,
      after: {'net': run.statement.net.minor},
    );
    return Ok(run);
  });

  @override
  Future<Result<PayoutRun, PayoutRefusal>> release({
    required String runId,
    required String actorUserId,
    required String reference,
    String? destination,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final found = await tx.execute(
      Sql.named('''
        SELECT state::text AS state, operator_id
          FROM payout_runs WHERE id = @id FOR UPDATE
      '''),
      parameters: {'id': TypedValue(Type.uuid, runId)},
    );
    if (found.isEmpty) return const Err(UnknownPayout());

    final row = found.first.toColumnMap();
    if (row['state'] != 'approved') {
      return Err(WrongPayoutState(row['state'] as String));
    }
    final operatorId = row['operator_id'].toString();

    // Read again, now, rather than trusting the numbers the draft carried. A
    // sale that settled between preparation and release belongs to the
    // operator, and paying yesterday's balance would leave it stranded until
    // somebody noticed.
    final balances = await _balances(tx, operatorId);

    final posting = payoutReleased(
      operatorId: operatorId,
      payable: balances.payable,
      tills: balances.perStation,
      reference: reference,
    );

    if (posting case Err(:final failure)) return Err(PayoutRefused(failure));

    final txnId = await _post(tx, posting.valueOrNull!, operatorId);

    await tx.execute(
      Sql.named('''
        UPDATE payout_runs
           SET state = 'paid', paid_at = now(), txn_id = @txn,
               reference = @reference,
               destination = COALESCE(@destination, destination)
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, runId),
        'txn': TypedValue(Type.uuid, txnId),
        'reference': TypedValue(Type.text, reference),
        'destination': TypedValue(Type.text, destination),
      },
      ignoreRows: true,
    );

    final run = (await _read(tx, runId))!;
    await _audit(
      tx,
      actorUserId: actorUserId,
      operatorId: operatorId,
      action: 'payout.release',
      runId: runId,
      after: {
        'reference': reference,
        'paid': balances.payable.minor - balances.tills.minor,
        'txnId': txnId,
      },
    );
    return Ok(run);
  });

  @override
  Future<List<PayoutRun>> pending({required String actorUserId}) =>
      _db.transaction(DbScope.platform(actorUserId), (tx) async {
        final rows = await tx.execute('''
          SELECT $_columns,
                 COALESCE(o.trading_name, o.legal_name) AS operator_name
            FROM payout_runs p
            JOIN operators o ON o.id = p.operator_id
           WHERE p.state IN ('draft', 'approved')
           ORDER BY p.prepared_at
        ''');
        return [for (final row in rows) _hydrate(row.toColumnMap())];
      });

  @override
  Future<List<PayoutRun>> statementsFor(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT $_columns FROM payout_runs p
             WHERE p.operator_id = @operator
             ORDER BY p.period_end DESC
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );
        return [for (final row in rows) _hydrate(row.toColumnMap())];
      });

  /// Listed rather than `*`: `state` is an enum, and a `SELECT *` hands it
  /// over as raw bytes. Naming the columns is also what makes adding one to
  /// the table a decision rather than an accident.
  static const _columns = '''
    p.id, p.operator_id, p.period_start, p.period_end, p.currency,
    p.online_sales_count, p.online_gross_minor,
    p.cash_sales_count, p.cash_gross_minor,
    p.commission_minor, p.service_fees_minor, p.refunds_minor,
    p.payable_minor, p.tills_minor, p.net_minor,
    p.state::text AS state, p.destination, p.prepared_at,
    p.approved_at, p.paid_at, p.reference
  ''';

  Future<PayoutRun?> _read(TxSession tx, String runId) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT $_columns,
               COALESCE(o.trading_name, o.legal_name) AS operator_name
          FROM payout_runs p
          JOIN operators o ON o.id = p.operator_id
         WHERE p.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, runId)},
    );
    if (rows.isEmpty) return null;
    return _hydrate(rows.first.toColumnMap());
  }

  /// What we owe this operator and what is in their drawers, right now.
  ///
  /// `payable:operator:<id>` is a liability, so its signed balance is
  /// negative when we owe money — the sign flip lives here, once, rather than
  /// in every caller that would eventually get it backwards.
  Future<({Money payable, Money tills, Map<String, Money> perStation})>
  _balances(TxSession tx, String operatorId) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT account, currency,
               sum(CASE WHEN direction = 'debit' THEN amount_minor
                        ELSE -amount_minor END)::bigint AS balance
          FROM ledger_entries
         WHERE account = @payable OR account LIKE @tills
         GROUP BY account, currency
      '''),
      parameters: {
        'payable': TypedValue(
          Type.text,
          LedgerAccount.payableOperator(operatorId),
        ),
        'tills': TypedValue(Type.text, 'cash:$operatorId:%:till'),
      },
    );

    var payable = Money(0, Currency.xaf);
    final perStation = <String, Money>{};

    for (final row in rows) {
      final r = row.toColumnMap();
      final account = r['account'] as String;
      final currency =
          Currency.byCode((r['currency'] as String).trim()) ?? Currency.xaf;
      final signed = _int(r['balance']);

      if (account.startsWith('payable:')) {
        payable = Money(-signed, currency);
      } else {
        // `cash:<operator>:<station>:till`
        perStation[account.split(':')[2]] = Money(signed, currency);
      }
    }

    final tills = perStation.values.fold(
      Money(0, payable.currency),
      (total, amount) => total + amount,
    );
    return (payable: payable, tills: tills, perStation: perStation);
  }

  Future<String> _post(
    TxSession tx,
    LedgerTransaction posting,
    String operatorId,
  ) async {
    final created = await tx.execute('SELECT gen_random_uuid() AS id');
    final txnId = created.first.toColumnMap()['id'].toString();

    for (final entry in posting.entries) {
      await tx.execute(
        Sql.named('''
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency,
             operator_id, memo)
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
    return txnId;
  }

  Future<void> _audit(
    TxSession tx, {
    required String actorUserId,
    required String operatorId,
    required String action,
    required String runId,
    required Map<String, Object?> after,
  }) => tx.execute(
    Sql.named('''
      INSERT INTO audit_log
        (actor_id, actor_type, action, subject_type, subject_id,
         operator_id, after_state)
      VALUES (@actor, 'platform_staff', @action, 'payout_run', @run,
              @operator, @after)
    '''),
    parameters: {
      'actor': TypedValue(Type.uuid, actorUserId),
      'action': TypedValue(Type.text, action),
      'run': TypedValue(Type.text, runId),
      'operator': TypedValue(Type.uuid, operatorId),
      'after': TypedValue(Type.jsonb, after),
    },
    ignoreRows: true,
  );

  static PayoutRun _hydrate(Map<String, dynamic> row) {
    final currency =
        Currency.byCode((row['currency'] as String).trim()) ?? Currency.xaf;
    Money money(Object? raw) => Money((raw as int?) ?? 0, currency);

    return PayoutRun(
      id: row['id'].toString(),
      statement: PayoutStatement(
        operatorId: row['operator_id'].toString(),
        from: row['period_start'] as DateTime,
        to: row['period_end'] as DateTime,
        onlineSalesCount: row['online_sales_count'] as int,
        onlineGross: money(row['online_gross_minor']),
        cashSalesCount: row['cash_sales_count'] as int,
        cashGross: money(row['cash_gross_minor']),
        commission: money(row['commission_minor']),
        serviceFees: money(row['service_fees_minor']),
        refunds: money(row['refunds_minor']),
        payable: money(row['payable_minor']),
        tills: money(row['tills_minor']),
      ),
      state: row['state'] as String,
      preparedAt: row['prepared_at'] as DateTime,
      operatorName: row['operator_name'] as String?,
      approvedAt: row['approved_at'] as DateTime?,
      paidAt: row['paid_at'] as DateTime?,
      destination: row['destination'] as String?,
      reference: row['reference'] as String?,
    );
  }

  static Money _xaf(Object? raw) => Money(_int(raw), Currency.xaf);

  /// `sum()` over a `bigint` comes back as `numeric`, which the driver hands
  /// over as a String. Parsed here rather than cast at every call site — the
  /// cast is the kind of thing that works until the first operator whose
  /// weekly total needs more than a Dart int's worth of digits, which is
  /// never, and fails immediately on an empty ledger, which is every new
  /// operator's first Monday.
  static int _int(Object? raw) => switch (raw) {
    final int value => value,
    final BigInt value => value.toInt(),
    null => 0,
    final other => int.tryParse('$other') ?? 0,
  };
}
