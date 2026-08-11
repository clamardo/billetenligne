import 'package:bel_contracts/bel_contracts.dart';
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
  const PostgresPlatformConsole(
    this._db, {
    this.timeZone = 'Africa/Brazzaville',
  });

  final Database _db;

  /// The market's timezone, passed to Postgres rather than hardcoded in SQL.
  /// A funnel bucketed by UTC splits an evening's sales across two rows here.
  final String timeZone;

  /// Which states a decision may be taken from.
  ///
  /// The table lives in `bel_contracts` because the back office greys the
  /// same buttons this guard refuses, and a screen whose affordances disagree
  /// with the server is a screen that produces 409s nobody can explain.
  /// **This is still the authority** — the SQL below is conditional on it, so
  /// two reviewers approving one application at the same moment produce one
  /// approval.
  static List<String> _from(OperatorDecision decision) =>
      OperatorLifecycle.allowedFrom[decision.name]!.toList();

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

    // The wizard's own answers. Absent for every operator onboarded before
    // self-signup existed, which is why it is nullable rather than empty: a
    // reviewer must be able to tell "applied and left step 4 blank" from
    // "arrived by SQL in the first week".
    final application = await tx.execute(
      Sql.named('''
            SELECT legal_form, registered_address, year_founded,
                   owner_name, owner_id_type, owner_id_number,
                   owner_phone, owner_email,
                   transport_licence_number, transport_licence_expires,
                   insurer_name, fleet_insurance_expires,
                   routes_served, fleet_size, station_count, daily_departures,
                   settlement_kind, settlement_account_name,
                   settlement_account_ref, settlement_verified_at,
                   agreement_accepted_at, submitted_at
              FROM operator_applications WHERE operator_id = @id
          '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );

    return OperatorDetail(
      summary: _summary(rows.first.toColumnMap()),
      application: application.isEmpty
          ? null
          : _application(
              application.first.toColumnMap(),
              rows.first.toColumnMap(),
            ),
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
        'from': TypedValue(Type.textArray, _from(decision)),
      },
    );

    if (moved.isEmpty) return const Err(DecisionRefusal.illegalTransition);

    // Activation is the moment an application becomes a business, and this
    // is what makes that true rather than ceremonial: the person who filled
    // in the wizard becomes the operator's first `org_owner`, in the same
    // transaction as the status change.
    //
    // Without it, "approved" meant somebody still had to run an INSERT by
    // hand before the operator could sign in — which is the phone call the
    // whole self-signup path exists to remove. `ON CONFLICT DO NOTHING`
    // because reinstating a suspended operator lands here too, and the owner
    // they already had is not a second owner.
    if (decision == OperatorDecision.activate) {
      await tx.execute(
        Sql.named('''
          INSERT INTO operator_staff (operator_id, user_id, roles, accepted_at)
          SELECT a.operator_id, a.applicant_user_id,
                 ARRAY['org_owner'], now()
            FROM operator_applications a
           WHERE a.operator_id = @id
          ON CONFLICT (operator_id, user_id) DO NOTHING
        '''),
        parameters: {'id': TypedValue(Type.uuid, operatorId)},
        ignoreRows: true,
      );
    }

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

  // ── The funnel ────────────────────────────────────────────────────────────

  /// Every day in the window, including the quiet ones.
  ///
  /// `generate_series` rather than `GROUP BY` alone, because a day with no
  /// holds must appear as a row of zeroes: the alert in `04-payments.md` §8
  /// compares each day with the one before it, and a missing Sunday silently
  /// turns that into Monday-against-Saturday.
  ///
  /// The cohort is keyed on the day the **hold** was created, not the day the
  /// booking or the payment landed. Somebody who holds a seat at 23h50 and
  /// pays at 00h10 is one journey, and splitting it across two rows would
  /// invent a failure on one day and a conversion from nothing on the next.
  static const _funnelSql = '''
    WITH days AS (
      SELECT generate_series(
               (now() AT TIME ZONE @tz)::date - (@days::int - 1),
               (now() AT TIME ZONE @tz)::date,
               interval '1 day')::date AS day
    ),
    cohort AS (
      SELECT (h.created_at AT TIME ZONE @tz)::date AS day,
             h.id, h.state::text AS hold_state,
             b.id AS booking_id, b.state::text AS booking_state
        FROM holds h
        LEFT JOIN bookings b ON b.hold_id = h.id
       WHERE h.created_at >= (((now() AT TIME ZONE @tz)::date
                               - (@days::int - 1)) AT TIME ZONE @tz)
         AND h.channel = @channel
         AND (@operator::uuid IS NULL OR h.operator_id = @operator::uuid)
    )
    SELECT d.day,
           count(c.id)::int AS held,
           count(c.booking_id)::int AS reserved,
           count(*) FILTER (
             WHERE c.booking_state IS NOT NULL
               AND c.booking_state NOT IN ('pending_payment', 'expired')
           )::int AS paid,
           count(*) FILTER (
             WHERE c.hold_state IN ('expired', 'released')
           )::int AS holds_lapsed,
           count(*) FILTER (
             WHERE EXISTS (
               SELECT 1 FROM payment_intents pi
                WHERE pi.booking_id = c.booking_id
                  AND pi.state::text IN ('failed', 'expired',
                                         'cancelled', 'indeterminate')
             )
           )::int AS payments_failed
      FROM days d LEFT JOIN cohort c ON c.day = d.day
     GROUP BY d.day
     ORDER BY d.day DESC
  ''';

  @override
  Future<List<FunnelDay>> funnel({
    required String actorUserId,
    int days = 14,
    String? operatorId,
    String channel = 'app',
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final rows = await tx.execute(
      Sql.named(_funnelSql),
      parameters: {
        'tz': timeZone,
        // Clamped rather than trusted: the window is a query parameter, and a
        // year of daily rows is a slow query somebody can ask for by typing.
        'days': TypedValue(Type.integer, days.clamp(1, 90)),
        'channel': channel,
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    return [
      for (final row in rows)
        FunnelDay(
          day: row[0] as DateTime,
          held: row[1] as int,
          reserved: row[2] as int,
          paid: row[3] as int,
          holdsLapsed: row[4] as int,
          paymentsFailed: row[5] as int,
        ),
    ];
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

  /// The application row and the operator row read as one record: legal
  /// name, RCCM and NIU live on `operators` because they are the operator's
  /// identity rather than the application's, and a reviewer does not care
  /// which table they came out of.
  static SubmittedApplication _application(
    Map<String, dynamic> a,
    Map<String, dynamic> o,
  ) => SubmittedApplication(
    submittedAt: a['submitted_at'] as DateTime?,
    settlementVerifiedAt: a['settlement_verified_at'] as DateTime?,
    facts: ApplicationFacts(
      legalName: o['legal_name'] as String?,
      tradingName: o['trading_name'] as String?,
      rccmNumber: o['rccm_number'] as String?,
      taxId: o['tax_id'] as String?,
      legalForm: a['legal_form'] as String?,
      registeredAddress: a['registered_address'] as String?,
      yearFounded: a['year_founded'] as int?,
      ownerName: a['owner_name'] as String?,
      ownerIdType: a['owner_id_type'] as String?,
      ownerIdNumber: a['owner_id_number'] as String?,
      ownerPhone: a['owner_phone'] as String?,
      ownerEmail: a['owner_email'] as String?,
      transportLicenceNumber: a['transport_licence_number'] as String?,
      transportLicenceExpires: _date(a['transport_licence_expires']),
      insurerName: a['insurer_name'] as String?,
      fleetInsuranceExpires: _date(a['fleet_insurance_expires']),
      routesServed: a['routes_served'] as String?,
      fleetSize: a['fleet_size'] as int?,
      stationCount: a['station_count'] as int?,
      dailyDepartures: a['daily_departures'] as int?,
      settlementKind: a['settlement_kind'] as String?,
      settlementAccountName: a['settlement_account_name'] as String?,
      settlementAccountRef: a['settlement_account_ref'] as String?,
      agreementAccepted: a['agreement_accepted_at'] != null,
    ),
  );

  static DateTime? _date(Object? v) => switch (v) {
    DateTime d => DateTime.utc(d.year, d.month, d.day),
    String s => DateTime.tryParse(s),
    _ => null,
  };

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
