import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

/// Inter-operator protection agreements against Postgres (`08-disruption.md`
/// §5).
///
/// Everything here runs on the **tenant** scope of whichever operator is
/// asking, and that is the whole point: 0019's policies let either party read
/// the row and only the proposer write it, so the adapter does not have to be
/// careful — the database refuses on its own. An agreement read under the
/// wrong tenant returns nothing rather than somebody else's terms.
final class PostgresProtection implements ProtectionDesk {
  const PostgresProtection(this._db);

  final Database _db;

  static const _columns = '''
    a.id::text                AS id,
    a.operator_a::text        AS operator_a,
    a.operator_b::text        AS operator_b,
    a.state::text             AS state,
    a.reciprocal              AS reciprocal,
    a.rebill_discount_bps     AS rebill_discount_bps,
    a.monthly_cap_seats       AS monthly_cap_seats,
    a.auto_accept_spare_above AS auto_accept_spare_above,
    a.proposed_by::text       AS proposed_by,
    a.proposed_at             AS proposed_at,
    a.accepted_at             AS accepted_at,
    a.ended_at                AS ended_at,
    a.ended_reason            AS ended_reason
  ''';

  @override
  Future<List<ProtectionAgreementView>> agreementsFor(
    String operatorId,
  ) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
            SELECT $_columns,
                   CASE WHEN a.operator_a = @me THEN a.operator_b
                        ELSE a.operator_a END ::text AS counterparty_id
              FROM protection_agreements a
             ORDER BY a.proposed_at DESC
          '''),
      parameters: {'me': TypedValue(Type.uuid, operatorId)},
    );
    if (rows.isEmpty) return const <ProtectionAgreementView>[];

    final ids = [for (final r in rows) r.toColumnMap()['id']! as String];

    final corridors = await tx.execute(
      Sql.named('''
            SELECT agreement_id::text AS agreement_id, city_low, city_high
              FROM protection_corridors
             WHERE agreement_id = ANY(@ids)
             ORDER BY city_low, city_high
          '''),
      parameters: {'ids': TypedValue(Type.uuidArray, ids)},
    );

    final byAgreement = <String, List<Corridor>>{};
    for (final row in corridors) {
      final c = row.toColumnMap();
      byAgreement
          .putIfAbsent(c['agreement_id']! as String, () => [])
          .add(Corridor(c['city_low']! as String, c['city_high']! as String));
    }

    // The names of the other companies, in one round trip. A per-row
    // lookup would be a query per agreement on a screen that lists them.
    final names = await tx.execute(
      Sql.named('SELECT id::text AS id, name FROM operator_names(@ids)'),
      parameters: {
        'ids': TypedValue(Type.uuidArray, [
          for (final r in rows) r.toColumnMap()['counterparty_id']! as String,
        ]),
      },
    );
    final nameOf = {
      for (final row in names)
        row.toColumnMap()['id']! as String:
            row.toColumnMap()['name']! as String,
    };

    // Seats already moved this calendar month, per agreement, so a
    // ceiling reads `31 / 40` on the screen rather than on refusal.
    final used = await _usedThisMonth(tx, ids);

    return [
      for (final row in rows)
        _view(
          row.toColumnMap(),
          me: operatorId,
          corridors: byAgreement[row.toColumnMap()['id']] ?? const [],
          names: nameOf,
          used: used,
        ),
    ];
  });

  @override
  Future<({ProtectionAgreementView? agreement, AgreementRefusal? refusal})>
  propose({
    required String operatorId,
    required String counterpartyCode,
    required List<Corridor> corridors,
    required String actorUserId,
    bool reciprocal = true,
    int rebillDiscountBps = 0,
    int? monthlyCapSeats,
    int? autoAcceptWhenSpareAbove,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    if (corridors.isEmpty) {
      return (agreement: null, refusal: const AgreementRefused(NoCorridors()));
    }

    // Named by code, not by id. An operator knows their competitor as
    // "TBV" — the id is ours and appears on no document either of them holds.
    //
    // Through the SECURITY DEFINER function 0019 defines, not by reading
    // `operators`: the table is tenant-isolated and a SELECT policy is
    // all-columns, so widening it to name a competitor would also expose that
    // competitor's negotiated commission. The function returns the two facts
    // any anonymous traveller already reads off a search result.
    final other = await tx.execute(
      Sql.named('''
        SELECT id::text AS id, name FROM operator_id_by_code(@code)
      '''),
      parameters: {'code': TypedValue(Type.text, counterpartyCode)},
    );
    if (other.isEmpty) {
      return (agreement: null, refusal: const UnknownCounterparty());
    }

    final counterpartyId = other.first.toColumnMap()['id']! as String;
    if (counterpartyId == operatorId) {
      return (agreement: null, refusal: const AgreementRefused(SameOperator()));
    }

    final (a, b) = ProtectionAgreement.partiesOf(operatorId, counterpartyId);

    final existing = await tx.execute(
      Sql.named('''
        SELECT id FROM protection_agreements
         WHERE operator_a = @a AND operator_b = @b
           AND state IN ('proposed', 'active')
      '''),
      parameters: {
        'a': TypedValue(Type.uuid, a),
        'b': TypedValue(Type.uuid, b),
      },
    );
    if (existing.isNotEmpty) {
      return (agreement: null, refusal: const AlreadyAgreed());
    }

    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO protection_agreements
          (operator_a, operator_b, proposed_by, proposed_by_user, reciprocal,
           rebill_discount_bps, monthly_cap_seats, auto_accept_spare_above)
        VALUES (@a, @b, @me, @actor, @reciprocal, @discount, @cap, @spare)
        RETURNING id::text AS id, proposed_at
      '''),
      parameters: {
        'a': TypedValue(Type.uuid, a),
        'b': TypedValue(Type.uuid, b),
        'me': TypedValue(Type.uuid, operatorId),
        'actor': TypedValue(Type.uuid, actorUserId),
        'reciprocal': TypedValue(Type.boolean, reciprocal),
        'discount': TypedValue(Type.integer, rebillDiscountBps),
        'cap': TypedValue(Type.integer, monthlyCapSeats),
        'spare': TypedValue(Type.integer, autoAcceptWhenSpareAbove),
      },
    );
    final row = inserted.first.toColumnMap();
    final id = row['id']! as String;

    for (final corridor in corridors) {
      await tx.execute(
        Sql.named('''
          INSERT INTO protection_corridors (agreement_id, city_low, city_high)
          VALUES (@id, @low, @high)
          ON CONFLICT DO NOTHING
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, id),
          'low': TypedValue(Type.text, corridor.first),
          'high': TypedValue(Type.text, corridor.second),
        },
        ignoreRows: true,
      );
    }

    await _audit(
      tx,
      actorUserId: actorUserId,
      operatorId: operatorId,
      agreementId: id,
      action: 'protection.proposed',
      after: {
        'counterparty': counterpartyId,
        'reciprocal': reciprocal,
        'rebillDiscountBps': rebillDiscountBps,
        'monthlyCapSeats': monthlyCapSeats,
        'corridors': [for (final c in corridors) c.key],
      },
    );

    return (
      agreement: ProtectionAgreementView(
        agreement: ProtectionAgreement(
          id: id,
          operatorA: a,
          operatorB: b,
          corridors: corridors,
          state: ProtectionAgreementState.proposed,
          proposedBy: operatorId,
          reciprocal: reciprocal,
          rebillDiscountBps: rebillDiscountBps,
          monthlyCapSeats: monthlyCapSeats,
          autoAcceptWhenSpareAbove: autoAcceptWhenSpareAbove,
        ),
        counterpartyId: counterpartyId,
        counterpartyName: other.first.toColumnMap()['name']! as String,
        proposedAt: row['proposed_at']! as DateTime,
        weProposed: true,
        seatsUsedThisMonth: 0,
      ),
      refusal: null,
    );
  });

  @override
  Future<({ProtectionAgreementView? agreement, AgreementRefusal? refusal})>
  decide({
    required String operatorId,
    required String agreementId,
    required String decision,
    required String actorUserId,
    String? reason,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT $_columns
          FROM protection_agreements a
         WHERE a.id = @id
           FOR UPDATE
      '''),
      parameters: {'id': TypedValue(Type.uuid, agreementId)},
    );
    if (rows.isEmpty) {
      return (agreement: null, refusal: const UnknownAgreement());
    }

    final row = rows.first.toColumnMap();
    final state = row['state']! as String;
    final proposedBy = row['proposed_by']! as String;

    // The rule the payout run runs on, one size down: the party that wrote
    // the terms is not the party that agrees to them.
    if (decision == 'accept' && proposedBy == operatorId) {
      return (
        agreement: null,
        refusal: const AgreementRefused(CannotAcceptOwnProposal()),
      );
    }

    final next = switch ((decision, state)) {
      ('accept', 'proposed') => 'active',
      ('decline', 'proposed') => 'ended',
      ('suspend', 'active') => 'suspended',
      ('resume', 'suspended') => 'active',
      ('end', 'active') ||
      ('end', 'suspended') ||
      ('end', 'proposed') => 'ended',
      _ => null,
    };
    if (next == null) {
      return (agreement: null, refusal: WrongAgreementState(state));
    }

    await tx.execute(
      Sql.named('''
        UPDATE protection_agreements
           SET state = @next::protection_agreement_state,
               accepted_at = CASE WHEN @next = 'active' AND accepted_at IS NULL
                                  THEN now() ELSE accepted_at END,
               accepted_by_user = CASE
                 WHEN @next = 'active' AND accepted_by_user IS NULL
                 THEN @actor ELSE accepted_by_user END,
               ended_at = CASE WHEN @next = 'ended' THEN now() ELSE ended_at END,
               ended_reason = CASE
                 WHEN @next = 'ended' THEN @reason ELSE ended_reason END
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, agreementId),
        'next': TypedValue(Type.text, next),
        'actor': TypedValue(Type.uuid, actorUserId),
        'reason': TypedValue(Type.text, reason),
      },
      ignoreRows: true,
    );

    await _audit(
      tx,
      actorUserId: actorUserId,
      operatorId: operatorId,
      agreementId: agreementId,
      action: 'protection.$decision',
      after: {'state': next, if (reason != null) 'reason': reason},
    );

    final reread = await tx.execute(
      Sql.named('''
        SELECT $_columns,
               CASE WHEN a.operator_a = @me THEN a.operator_b
                    ELSE a.operator_a END ::text AS counterparty_id
          FROM protection_agreements a
         WHERE a.id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, agreementId),
        'me': TypedValue(Type.uuid, operatorId),
      },
    );
    final fresh = reread.first.toColumnMap();
    final counterpartyId = fresh['counterparty_id']! as String;

    final corridors = await tx.execute(
      Sql.named('''
        SELECT city_low, city_high FROM protection_corridors
         WHERE agreement_id = @id ORDER BY city_low, city_high
      '''),
      parameters: {'id': TypedValue(Type.uuid, agreementId)},
    );

    final names = await tx.execute(
      Sql.named('SELECT id::text AS id, name FROM operator_names(@ids)'),
      parameters: {
        'ids': TypedValue(Type.uuidArray, [counterpartyId]),
      },
    );

    return (
      agreement: _view(
        fresh,
        me: operatorId,
        corridors: [
          for (final c in corridors)
            Corridor(
              c.toColumnMap()['city_low']! as String,
              c.toColumnMap()['city_high']! as String,
            ),
        ],
        names: {
          for (final row in names)
            row.toColumnMap()['id']! as String:
                row.toColumnMap()['name']! as String,
        },
        used: await _usedThisMonth(tx, [agreementId]),
      ),
      refusal: null,
    );
  });

  /// Seats moved under each agreement since the first of this month.
  ///
  /// Zero everywhere until the movements themselves are built — the query is
  /// here rather than a hardcoded `0` so the ceiling on the screen is the
  /// ledger's answer the day it stops being zero.
  Future<Map<String, int>> _usedThisMonth(
    TxSession tx,
    List<String> agreementIds,
  ) async {
    if (agreementIds.isEmpty) return const {};
    final rows = await tx.execute(
      Sql.named('''
        SELECT agreement_id::text AS agreement_id,
               COALESCE(sum(seats), 0)::int AS seats
          FROM protection_movements
         WHERE agreement_id = ANY(@ids)
           AND moved_at >= date_trunc('month', now())
         GROUP BY agreement_id
      '''),
      parameters: {'ids': TypedValue(Type.uuidArray, agreementIds)},
    );
    return {
      for (final row in rows)
        row.toColumnMap()['agreement_id']! as String:
            row.toColumnMap()['seats']! as int,
    };
  }

  ProtectionAgreementView _view(
    Map<String, dynamic> row, {
    required String me,
    required List<Corridor> corridors,
    required Map<String, String> names,
    required Map<String, int> used,
  }) {
    final id = row['id']! as String;
    final counterpartyId =
        row['counterparty_id'] as String? ??
        (row['operator_a'] == me
            ? row['operator_b']! as String
            : row['operator_a']! as String);

    return ProtectionAgreementView(
      agreement: ProtectionAgreement(
        id: id,
        operatorA: row['operator_a']! as String,
        operatorB: row['operator_b']! as String,
        corridors: corridors,
        state: ProtectionAgreementState.values.firstWhere(
          (s) => s.name == row['state'],
        ),
        proposedBy: row['proposed_by']! as String,
        reciprocal: row['reciprocal']! as bool,
        rebillDiscountBps: row['rebill_discount_bps']! as int,
        monthlyCapSeats: row['monthly_cap_seats'] as int?,
        autoAcceptWhenSpareAbove: row['auto_accept_spare_above'] as int?,
      ),
      counterpartyId: counterpartyId,
      counterpartyName: names[counterpartyId] ?? counterpartyId,
      proposedAt: row['proposed_at']! as DateTime,
      weProposed: row['proposed_by'] == me,
      seatsUsedThisMonth: used[id] ?? 0,
      acceptedAt: row['accepted_at'] as DateTime?,
      endedAt: row['ended_at'] as DateTime?,
      endedReason: row['ended_reason'] as String?,
    );
  }

  Future<void> _audit(
    TxSession tx, {
    required String actorUserId,
    required String operatorId,
    required String agreementId,
    required String action,
    required Map<String, Object?> after,
  }) => tx.execute(
    Sql.named('''
      INSERT INTO audit_log
        (actor_id, actor_type, action, subject_type, subject_id,
         operator_id, after_state)
      VALUES (@actor, 'operator_staff', @action, 'protection_agreement',
              @subject, @operator, @after)
    '''),
    parameters: {
      'actor': TypedValue(Type.uuid, actorUserId),
      'action': TypedValue(Type.text, action),
      'subject': TypedValue(Type.text, agreementId),
      'operator': TypedValue(Type.uuid, operatorId),
      'after': TypedValue(Type.jsonb, after),
    },
    ignoreRows: true,
  );
}

/// An agreement that covers no road at all.
final class NoCorridors extends DomainFailure {
  const NoCorridors();
  @override
  String get code => 'agreement.no_corridors';
}
