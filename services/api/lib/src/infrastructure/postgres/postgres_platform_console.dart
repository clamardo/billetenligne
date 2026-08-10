import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/platform_console.dart';
import '../db/database.dart';

/// The back office, on the platform surface.
///
/// Every statement runs under `DbScope.platform(actor)` — the `bel_admin`
/// role, whose policies say `operator_id = app_tenant_id() OR
/// app_is_platform()`. There is no tenant clause to add here and that is the
/// point of the surface: these queries are *meant* to cross tenants, and the
/// control is not a WHERE clause but the audit row written beside them.
///
/// The lifecycle transitions below are enforced in SQL as well as in Dart —
/// `WHERE status = ANY(@from)` — for the same reason the payment capture is
/// conditional on `pending_payment`: two reviewers approving one application
/// at the same moment must produce one approval.
final class PostgresPlatformConsole implements PlatformConsole {
  const PostgresPlatformConsole(this._db);

  final Database _db;

  /// Which states a decision may be taken from.
  ///
  /// `03-operator-lifecycle.md` §1, as a table rather than as a chain of ifs.
  /// Approving something already active is not a no-op — it is a sign the
  /// reviewer is looking at the wrong row.
  static const _from = <OperatorDecision, List<String>>{
    OperatorDecision.approve: [
      'registered',
      'application_draft',
      'under_review',
      'kyb_verifying',
      'info_requested',
    ],
    OperatorDecision.activate: ['approved'],
    OperatorDecision.requestInfo: [
      'registered',
      'under_review',
      'kyb_verifying',
    ],
    OperatorDecision.reject: [
      'registered',
      'application_draft',
      'under_review',
      'kyb_verifying',
      'info_requested',
    ],
    OperatorDecision.suspend: ['approved', 'active'],
    OperatorDecision.reinstate: ['suspended'],
  };

  static const _summaryColumns = '''
    o.id, o.code, o.legal_name, o.trading_name, o.market_code,
    o.status::text AS status, o.rccm_number, o.tax_id, o.commission_bps,
    o.created_at
  ''';

  /// Counts in one pass rather than one query per operator. A queue screen
  /// asking five questions about each of forty operators is two hundred round
  /// trips, and it is the kind of thing that is fine until it is a Monday.
  static const _counts = '''
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n,
             count(*) FILTER (
               WHERE expires_at IS NOT NULL
                 AND expires_at < now() + interval '30 days'
             )::int AS expiring
        FROM kyb_documents d WHERE d.operator_id = o.id
    ) docs ON TRUE
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n FROM vehicles v WHERE v.operator_id = o.id
    ) fleet ON TRUE
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n FROM routes r WHERE r.operator_id = o.id
    ) lines ON TRUE
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS n
        FROM operator_staff s
       WHERE s.operator_id = o.id AND s.revoked_at IS NULL
    ) people ON TRUE
  ''';

  @override
  Future<List<OperatorSummary>> operators({
    required String actorUserId,
    Set<String> statuses = const {},
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT $_summaryColumns,
               docs.n AS doc_count, docs.expiring AS doc_expiring,
               fleet.n AS vehicle_count, lines.n AS route_count,
               people.n AS staff_count
          FROM operators o $_counts
         WHERE (@statuses::text[] IS NULL
                OR o.status::text = ANY(@statuses::text[]))
         ORDER BY o.created_at
      '''),
      parameters: {
        'statuses': TypedValue(
          Type.textArray,
          statuses.isEmpty ? null : statuses.toList(),
        ),
      },
    );

    return [for (final row in rows) _summary(row.toColumnMap())];
  });

  @override
  Future<OperatorDetail?> operatorDetail(
    String operatorId, {
    required String actorUserId,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
            SELECT $_summaryColumns,
                   docs.n AS doc_count, docs.expiring AS doc_expiring,
                   fleet.n AS vehicle_count, lines.n AS route_count,
                   people.n AS staff_count
              FROM operators o $_counts
             WHERE o.id = @id
          '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    if (rows.isEmpty) return null;

    final documents = await tx.execute(
      Sql.named('''
            SELECT id, doc_type, storage_key, expires_at, verified_at,
                   rejected_reason, created_at
              FROM kyb_documents WHERE operator_id = @id
             ORDER BY created_at
          '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );

    final trail = await tx.execute(
      Sql.named('''
            SELECT action, actor_type, actor_id, reason, subject_type,
                   subject_id, created_at
              FROM audit_log
             WHERE operator_id = @id
             ORDER BY created_at DESC
             LIMIT 50
          '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );

    return OperatorDetail(
      summary: _summary(rows.first.toColumnMap()),
      documents: [
        for (final row in documents)
          KybDocument(
            id: row.toColumnMap()['id'].toString(),
            docType: row.toColumnMap()['doc_type'] as String,
            storageKey: row.toColumnMap()['storage_key'] as String,
            expiresAt: row.toColumnMap()['expires_at'] as DateTime?,
            verifiedAt: row.toColumnMap()['verified_at'] as DateTime?,
            rejectedReason: row.toColumnMap()['rejected_reason'] as String?,
            createdAt: row.toColumnMap()['created_at'] as DateTime,
          ),
      ],
      trail: [
        for (final row in trail)
          AuditEntry(
            action: row.toColumnMap()['action'] as String,
            actorType: row.toColumnMap()['actor_type'] as String,
            actorId: row.toColumnMap()['actor_id']?.toString(),
            reason: row.toColumnMap()['reason'] as String?,
            subjectType: row.toColumnMap()['subject_type'] as String?,
            subjectId: row.toColumnMap()['subject_id'] as String?,
            createdAt: row.toColumnMap()['created_at'] as DateTime,
          ),
      ],
    );
  });

  @override
  Future<Result<OperatorSummary, DecisionRefusal>> decide({
    required String operatorId,
    required OperatorDecision decision,
    required String actorUserId,
    required String reason,
    String? detail,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final before = await _statusOf(tx, operatorId);
    if (before == null) return const Err(DecisionRefusal.unknownOperator);

    // The transition and the audit row are one transaction. A decision
    // recorded without a trail, or a trail without the decision, are both
    // worse than neither.
    final moved = await tx.execute(
      Sql.named('''
        UPDATE operators
           SET status = @to::operator_status,
               approved_at = CASE WHEN @to = 'active'
                                  THEN COALESCE(approved_at, now())
                                  ELSE approved_at END,
               suspended_at = CASE WHEN @to = 'suspended' THEN now()
                                   WHEN @to = 'active' THEN NULL
                                   ELSE suspended_at END,
               suspended_reason = CASE WHEN @to = 'suspended' THEN @reason
                                       WHEN @to = 'active' THEN NULL
                                       ELSE suspended_reason END
         WHERE id = @id AND status::text = ANY(@from::text[])
        RETURNING id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, operatorId),
        'to': TypedValue(Type.text, decision.status),
        'reason': TypedValue(Type.text, reason),
        'from': TypedValue(Type.textArray, _from[decision]!),
      },
    );

    if (moved.isEmpty) return const Err(DecisionRefusal.illegalTransition);

    await _audit(
      tx,
      actorUserId: actorUserId,
      action: decision.action,
      reason: detail == null || detail.isEmpty ? reason : '$reason — $detail',
      operatorId: operatorId,
      subjectType: 'operator',
      subjectId: operatorId,
      before: {'status': before},
      after: {'status': decision.status},
    );

    return Ok((await _reread(tx, operatorId))!);
  });

  @override
  Future<Result<OperatorSummary, DecisionRefusal>> setCommission({
    required String operatorId,
    required CommissionTerm term,
    required String actorUserId,
    required String reason,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    // Read the old rate first rather than in a RETURNING subquery: the
    // subquery would be evaluated against the row this statement is in the
    // middle of writing, which is a coin toss dressed up as a value.
    final was = await tx.execute(
      Sql.named('SELECT commission_bps FROM operators WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    if (was.isEmpty) return const Err(DecisionRefusal.unknownOperator);

    await tx.execute(
      Sql.named('UPDATE operators SET commission_bps = @bps WHERE id = @id'),
      parameters: {
        'id': TypedValue(Type.uuid, operatorId),
        'bps': TypedValue(Type.integer, term.bps),
      },
      ignoreRows: true,
    );

    // Old rate and new rate in one row. This is the number an operator will
    // argue about six months later, and "what did we agree, and when" is
    // exactly what an audit log is for.
    await _audit(
      tx,
      actorUserId: actorUserId,
      action: 'operator.commission',
      reason: reason,
      operatorId: operatorId,
      subjectType: 'operator',
      subjectId: operatorId,
      before: {'commissionBps': was.first.toColumnMap()['commission_bps']},
      after: {'commissionBps': term.bps},
    );

    return Ok((await _reread(tx, operatorId))!);
  });

  @override
  Future<void> recordRead({
    required String actorUserId,
    required String reason,
    required String action,
    String? subjectType,
    String? subjectId,
    String? operatorId,
    String? traceId,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    await _audit(
      tx,
      actorUserId: actorUserId,
      action: action,
      reason: reason,
      operatorId: operatorId,
      subjectType: subjectType,
      subjectId: subjectId,
      traceId: traceId,
    );
  });

  // ── Reconciliation ────────────────────────────────────────────────────────

  /// One query, every join the screen needs.
  ///
  /// A reconciliation queue that needs a second request per row to name the
  /// traveller is a queue somebody works with twenty tabs open, and the
  /// person on the other end of it has already been waiting fifteen minutes.
  static const _unresolvedSelect = '''
    SELECT i.id, i.state::text AS state, i.rail_id, i.amount_minor,
           i.currency::text AS currency, i.msisdn, i.created_at,
           i.last_polled_at, i.poll_attempts, i.rail_transaction_id,
           b.id AS booking_id, b.ref AS booking_ref,
           b.state::text AS booking_state,
           o.id AS operator_id, o.legal_name AS operator_name,
           u.phone_e164 AS traveller_phone, u.email AS traveller_email,
           d.departs_at,
           r.origin_city, r.destination_city
      FROM payment_intents i
      JOIN bookings b   ON b.id = i.booking_id
      JOIN operators o  ON o.id = i.operator_id
      LEFT JOIN user_accounts u ON u.id = b.purchaser_user_id
      LEFT JOIN departures d ON d.id = b.departure_id
      LEFT JOIN routes r ON r.id = d.route_id
  ''';

  @override
  Future<List<UnresolvedPayment>> unresolvedPayments({
    required String actorUserId,
    int limit = 100,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        $_unresolvedSelect
         WHERE i.state = 'indeterminate'
            OR (i.state IN ('pending', 'authorized')
                AND i.expires_at IS NOT NULL AND i.expires_at < now())
         ORDER BY i.created_at
         LIMIT @limit
      '''),
      parameters: {'limit': TypedValue(Type.integer, limit)},
    );
    return [for (final row in rows) _unresolved(row.toColumnMap())];
  });

  @override
  Future<UnresolvedPayment?> unresolvedPayment(
    String intentId, {
    required String actorUserId,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final rows = await tx.execute(
      Sql.named('$_unresolvedSelect WHERE i.id = @id'),
      parameters: {'id': TypedValue(Type.uuid, intentId)},
    );
    return rows.isEmpty ? null : _unresolved(rows.first.toColumnMap());
  });

  static UnresolvedPayment _unresolved(Map<String, dynamic> r) {
    final currency = Currency.byCode((r['currency'] as String).trim())!;
    return UnresolvedPayment(
      intentId: r['id'].toString(),
      state: r['state'] as String,
      railId: r['rail_id'] as String,
      amount: Money(r['amount_minor'] as int, currency),
      payerMsisdn: (r['msisdn'] as String?) ?? '',
      createdAt: r['created_at'] as DateTime,
      lastPolledAt: r['last_polled_at'] as DateTime?,
      pollAttempts: (r['poll_attempts'] as int?) ?? 0,
      railTransactionId: r['rail_transaction_id'] as String?,
      bookingId: r['booking_id'].toString(),
      bookingRef: r['booking_ref'] as String,
      bookingState: r['booking_state'] as String,
      operatorId: r['operator_id'].toString(),
      operatorName: r['operator_name'] as String,
      travellerPhone: r['traveller_phone'] as String?,
      travellerEmail: r['traveller_email'] as String?,
      departsAt: r['departs_at'] as DateTime?,
      originCity: r['origin_city'] as String?,
      destinationCity: r['destination_city'] as String?,
    );
  }

  // ── Plumbing ──────────────────────────────────────────────────────────────

  Future<String?> _statusOf(TxSession tx, String operatorId) async {
    final rows = await tx.execute(
      Sql.named('SELECT status::text AS status FROM operators WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap()['status'] as String;
  }

  Future<OperatorSummary?> _reread(TxSession tx, String operatorId) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT $_summaryColumns,
               docs.n AS doc_count, docs.expiring AS doc_expiring,
               fleet.n AS vehicle_count, lines.n AS route_count,
               people.n AS staff_count
          FROM operators o $_counts
         WHERE o.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    return rows.isEmpty ? null : _summary(rows.first.toColumnMap());
  }

  Future<void> _audit(
    TxSession tx, {
    required String actorUserId,
    required String action,
    required String reason,
    String? operatorId,
    String? subjectType,
    String? subjectId,
    String? traceId,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
  }) async {
    await tx.execute(
      Sql.named('''
        INSERT INTO audit_log
          (actor_id, actor_type, action, subject_type, subject_id,
           operator_id, reason, before_state, after_state, trace_id)
        VALUES (@actor, 'platform_staff', @action, @subjectType, @subjectId,
                @operator, @reason, @before, @after, @trace)
      '''),
      parameters: {
        'actor': TypedValue(Type.uuid, actorUserId),
        'action': TypedValue(Type.text, action),
        'subjectType': TypedValue(Type.text, subjectType),
        'subjectId': TypedValue(Type.text, subjectId),
        'operator': TypedValue(Type.uuid, operatorId),
        'reason': TypedValue(Type.text, reason),
        'before': TypedValue(Type.jsonb, before),
        'after': TypedValue(Type.jsonb, after),
        'trace': TypedValue(Type.text, traceId),
      },
      ignoreRows: true,
    );
  }

  static OperatorSummary _summary(Map<String, dynamic> r) => OperatorSummary(
    id: r['id'].toString(),
    code: r['code'] as String,
    legalName: r['legal_name'] as String,
    tradingName: r['trading_name'] as String?,
    status: r['status'] as String,
    marketCode: r['market_code'] as String,
    rccmNumber: r['rccm_number'] as String?,
    taxId: r['tax_id'] as String?,
    commission: CommissionTerm(r['commission_bps'] as int),
    createdAt: r['created_at'] as DateTime,
    documentCount: (r['doc_count'] as int?) ?? 0,
    expiringDocumentCount: (r['doc_expiring'] as int?) ?? 0,
    vehicleCount: (r['vehicle_count'] as int?) ?? 0,
    routeCount: (r['route_count'] as int?) ?? 0,
    staffCount: (r['staff_count'] as int?) ?? 0,
  );
}
