import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/application/ports/ticket_issuer.dart';
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
  const PostgresProtection(this._db, {TicketIssuer? issuer}) : _issuer = issuer;

  final Database _db;

  /// Every ticket that changes hands is re-signed: the QR carries the
  /// departure and the operator as well as the seat (ADR-0007), and a ticket
  /// still naming the broken coach scans as the wrong trip at the door.
  final TicketIssuer? _issuer;

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

  // ── The request, and the movement it causes (§2.3) ────────────────────────

  @override
  Future<List<ProtectionRequestView>> requestsFor(
    String operatorId,
  ) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Read through the definer function 0022 defines, not through a join.
    // A request names two departures owned by two different companies, and
    // `departures` is tenant-isolated — so a plain join drops whichever half
    // is not ours, silently, because RLS filters rows rather than raising:
    // an empty queue on the console of the company being asked for help.
    final rows = await tx.execute('''
          SELECT id::text                    AS id,
                 agreement_id::text          AS agreement_id,
                 sending_operator_id::text   AS sending_operator_id,
                 receiving_operator_id::text AS receiving_operator_id,
                 from_departure_id::text     AS from_departure_id,
                 to_departure_id::text       AS to_departure_id,
                 seats_requested, state, note, requested_at,
                 auto_accepted, seats_moved, decline_reason,
                 departs_at, replacement_departs_at, route_code, seats_free,
                 replacement_fare_minor::int AS replacement_fare_minor,
                 replacement_currency, discount_bps,
                 counterparty_id::text       AS counterparty_id
            FROM protection_queue()
        ''');
    if (rows.isEmpty) return const <ProtectionRequestView>[];

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

    return [
      for (final row in rows) _request(row.toColumnMap(), operatorId, nameOf),
    ];
  });

  @override
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  request({
    required String operatorId,
    required String departureId,
    required String replacementDepartureId,
    required String actorUserId,
    required DateTime now,
    String? note,
  }) async {
    final written = await _db.transaction(DbScope.tenant(operatorId), (
      tx,
    ) async {
      // The broken departure, under our own tenancy: it is ours, and asking
      // about somebody else's is not something this route can do.
      final source = await tx.execute(
        Sql.named('''
          SELECT d.id, d.departs_at, r.origin_city, r.destination_city,
                 (SELECT count(*) FROM booking_seats bs
                    JOIN bookings b ON b.id = bs.booking_id
                   WHERE b.departure_id = d.id AND b.state = 'confirmed')::int
                   AS seats,
                 (SELECT x.id FROM disruptions x
                   WHERE x.departure_id = d.id AND x.resolved_at IS NULL
                   LIMIT 1)::text AS disruption_id
            FROM departures d JOIN routes r ON r.id = d.route_id
           WHERE d.id = @id AND d.operator_id = @operator
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, departureId),
          'operator': TypedValue(Type.uuid, operatorId),
        },
      );
      if (source.isEmpty) {
        return (id: null, refusal: const UnknownRequest() as AgreementRefusal);
      }
      final broken = source.first.toColumnMap();
      final seatsNeeded = broken['seats']! as int;
      if (seatsNeeded == 0) {
        return (
          id: null,
          refusal: const NobodyCouldBeMoved() as AgreementRefusal,
        );
      }

      // The other company's departure, through the definer function 0021
      // defines. A competitor's `departures` row is tenant-isolated and
      // carries their pricing; what a rescue needs to know is when it leaves,
      // whether it is on sale and how many seats are free.
      final target = await tx.execute(
        Sql.named('''
          SELECT operator_id::text AS operator_id, origin_city,
                 destination_city, departs_at, status, seats_free
            FROM protection_offer(@departure)
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, replacementDepartureId),
        },
      );
      if (target.isEmpty) {
        return (id: null, refusal: const UnknownRequest() as AgreementRefusal);
      }
      final offer = target.first.toColumnMap();
      final receivingId = offer['operator_id']! as String;

      final live = await _liveAgreement(tx, operatorId, receivingId);

      // The same function the console calls before it draws option ③ — the
      // corridor, the direction, the monthly ceiling (ADR-0004).
      final refusal = refuseProtection(
        agreement: live?.agreement,
        requester: operatorId,
        origin: broken['origin_city']! as String,
        destination: broken['destination_city']! as String,
        seats: seatsNeeded,
        seatsUsedThisMonth: live?.seatsUsedThisMonth ?? 0,
      );
      if (refusal != null) {
        return (id: null, refusal: AgreementRefused(refusal));
      }

      // And the replacement has to be one the passengers can physically
      // reach: later, and on sale. Judged by the domain, once. The route
      // check is the corridor above — two operators run the same road under
      // different route ids, which is the whole point of an agreement.
      final unusable = refuseReplacement(
        departureId: departureId,
        replacementId: replacementDepartureId,
        routeId: 'corridor',
        replacementRouteId: 'corridor',
        replacementStatus: offer['status']! as String,
        departsAt: broken['departs_at']! as DateTime,
        replacementDepartsAt: offer['departs_at']! as DateTime,
        now: now,
      );
      if (unusable != null) {
        return (
          id: null,
          refusal: AgreementRefused(_RebookingAsFailure(unusable)),
        );
      }

      final inserted = await tx.execute(
        Sql.named('''
          INSERT INTO protection_requests
            (agreement_id, sending_operator_id, receiving_operator_id,
             from_departure_id, to_departure_id, disruption_id,
             seats_requested, note, requested_by_user)
          VALUES (@agreement, @me, @them, @from, @to, @disruption, @seats,
                  @note, @actor)
          ON CONFLICT DO NOTHING
          RETURNING id::text AS id
        '''),
        parameters: {
          'agreement': TypedValue(Type.uuid, live!.agreement.id),
          'me': TypedValue(Type.uuid, operatorId),
          'them': TypedValue(Type.uuid, receivingId),
          'from': TypedValue(Type.uuid, departureId),
          'to': TypedValue(Type.uuid, replacementDepartureId),
          'disruption': TypedValue(Type.uuid, broken['disruption_id']),
          'seats': TypedValue(Type.integer, seatsNeeded),
          'note': TypedValue(Type.text, note),
          'actor': TypedValue(Type.uuid, actorUserId),
        },
      );

      // A dispatcher tapping twice on a bad connection must not queue the
      // same rescue on the receiving console twice — the second read as
      // another forty-two people needing seats. The partial index refuses it;
      // from the dispatcher's side the ask has happened either way, so this
      // is not an error.
      if (inserted.isEmpty) return (id: null, refusal: null);

      final id = inserted.first.toColumnMap()['id']! as String;

      await _audit(
        tx,
        actorUserId: actorUserId,
        operatorId: operatorId,
        agreementId: live.agreement.id,
        action: 'protection.requested',
        after: {
          'toDepartureId': replacementDepartureId,
          'seatsRequested': seatsNeeded,
          'receivingOperatorId': receivingId,
        },
      );

      // The receiving operator's console has to light up without somebody
      // refreshing it, and their dispatcher may not be at a screen at all
      // (§4). Queued, never sent inline with this request (ADR-0019).
      await tx.execute(
        Sql.named('''
          INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                              dedupe_key)
          VALUES ('protection', @id, 'protection.requested',
                  jsonb_build_object('requestId', @id::text),
                  'protection.requested:' || @id::text)
          ON CONFLICT (dedupe_key) DO NOTHING
        '''),
        parameters: {'id': TypedValue(Type.uuid, id)},
        ignoreRows: true,
      );

      return (id: id, refusal: null);
    });

    if (written.refusal != null) {
      return (request: null, refusal: written.refusal);
    }

    // Re-read through the same query every other caller uses, so the answer a
    // dispatcher gets back is the row their queue will show a second later.
    final mine = await requestsFor(operatorId);
    final found = mine
        .where(
          (r) => written.id == null
              ? r.isPending &&
                    r.fromDepartureId == departureId &&
                    r.toDepartureId == replacementDepartureId
              : r.id == written.id,
        )
        .firstOrNull;
    return found == null
        ? (request: null, refusal: const UnknownRequest())
        : (request: found, refusal: null);
  }

  @override
  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})>
  decideRequest({
    required String operatorId,
    required String requestId,
    required String decision,
    required String actorUserId,
    required DateTime now,
    String? reason,
  }) async {
    // Authorised under the receiving operator's own tenancy. The movement
    // itself needs both sides and therefore cannot run here — see
    // [_applyProtection] for why the privilege moves and what re-checks the
    // consent once it has.
    final state = await _db.transaction(DbScope.tenant(operatorId), (tx) async {
      final rows = await tx.execute(
        Sql.named('''
          SELECT q.state::text AS state,
                 q.agreement_id::text AS agreement_id,
                 q.receiving_operator_id::text AS receiving_operator_id
            FROM protection_requests q
           WHERE q.id = @id
        '''),
        parameters: {'id': TypedValue(Type.uuid, requestId)},
      );
      if (rows.isEmpty) return null;
      final row = rows.first.toColumnMap();
      // The read policy shows a request to both parties; only the receiver
      // answers it. Checked here as well as in the policy, so the refusal is
      // a sentence rather than a zero-row UPDATE.
      if (row['receiving_operator_id'] != operatorId) return null;
      return row;
    });

    if (state == null) {
      return (request: null, refusal: const UnknownRequest());
    }
    final current = state['state']! as String;
    if (current != 'pending') {
      return (request: null, refusal: WrongRequestState(current));
    }

    if (decision == 'decline') {
      await _db.transaction(DbScope.tenant(operatorId), (tx) async {
        await tx.execute(
          Sql.named('''
            UPDATE protection_requests
               SET state = 'declined', decided_at = now(),
                   decided_by_user = @actor, decline_reason = @reason
             WHERE id = @id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, requestId),
            'actor': TypedValue(Type.uuid, actorUserId),
            'reason': TypedValue(Type.text, reason),
          },
          ignoreRows: true,
        );
        await _audit(
          tx,
          actorUserId: actorUserId,
          operatorId: operatorId,
          agreementId: state['agreement_id']! as String,
          action: 'protection.declined',
          after: {'requestId': requestId, if (reason != null) 'reason': reason},
        );
      });
      return _reread(operatorId, requestId);
    }

    if (decision != 'accept') {
      return (request: null, refusal: WrongRequestState(current));
    }

    final failed = await _applyProtection(
      requestId: requestId,
      actorUserId: actorUserId,
      autoAccepted: false,
    );
    if (failed != null) return (request: null, refusal: failed);

    return _reread(operatorId, requestId);
  }

  Future<({ProtectionRequestView? request, AgreementRefusal? refusal})> _reread(
    String operatorId,
    String requestId,
  ) async {
    final mine = await requestsFor(operatorId);
    final found = mine.where((r) => r.id == requestId).firstOrNull;
    return found == null
        ? (request: null, refusal: const UnknownRequest())
        : (request: found, refusal: null);
  }

  /// Moves the passengers, reissues their tickets under the receiving
  /// operator, and settles the rebill — all in one transaction.
  ///
  /// **This is the only operation in the system that crosses a tenant
  /// boundary, and it runs under the platform scope.** Not for convenience:
  /// the bookings belong to the sending operator and the seats to the
  /// receiving one, and neither tenant can see both halves, so no operator
  /// connection can perform it at all. The privilege moves and the consent is
  /// re-checked here — the agreement must still be active and the request
  /// must still be pending — which is the same shape as the SECURITY DEFINER
  /// transition in migration 0015: the escalation is narrow, in one function,
  /// and the thing it would otherwise trust is verified inside it.
  ///
  /// Returns null on success, or the refusal to report.
  Future<AgreementRefusal?> _applyProtection({
    required String requestId,
    required String actorUserId,
    required bool autoAccepted,
  }) => _db.transaction(DbScope.platform(actorUserId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT q.state::text                 AS state,
               q.sending_operator_id::text   AS sending_operator_id,
               q.receiving_operator_id::text AS receiving_operator_id,
               q.from_departure_id::text     AS from_departure_id,
               q.to_departure_id::text       AS to_departure_id,
               a.state::text                 AS agreement_state,
               a.rebill_discount_bps         AS discount_bps
          FROM protection_requests q
          JOIN protection_agreements a ON a.id = q.agreement_id
         WHERE q.id = @id
           FOR UPDATE OF q
      '''),
      parameters: {'id': TypedValue(Type.uuid, requestId)},
    );
    if (rows.isEmpty) return const UnknownRequest();
    final row = rows.first.toColumnMap();

    if (row['state'] != 'pending') {
      return WrongRequestState(row['state']! as String);
    }
    // The consent, re-checked at the moment it is used rather than trusted
    // from when the request was written. An agreement suspended in between
    // authorises nothing, and this is the transaction that would otherwise
    // act on a stale yes.
    if (row['agreement_state'] != 'active') {
      return const AgreementRefused(NoAgreement());
    }

    final sending = row['sending_operator_id']! as String;
    final receiving = row['receiving_operator_id']! as String;
    final from = row['from_departure_id']! as String;
    final to = row['to_departure_id']! as String;

    // Both departures locked, in id order: two rescues between the same pair
    // of coaches in opposite directions is a deadlock on exactly the morning
    // it happens.
    final ids = [from, to]..sort();
    await tx.execute(
      Sql.named(
        'SELECT id FROM departures WHERE id = ANY(@ids) ORDER BY id FOR UPDATE',
      ),
      parameters: {'ids': TypedValue(Type.uuidArray, ids)},
    );

    final parties = await tx.execute(
      Sql.named('''
        SELECT b.id, b.created_at, count(bs.seat_label) AS seats
          FROM bookings b
          JOIN booking_seats bs ON bs.booking_id = b.id
         WHERE b.departure_id = @id AND b.state = 'confirmed'
         GROUP BY b.id, b.created_at
         ORDER BY b.created_at
      '''),
      parameters: {'id': TypedValue(Type.uuid, from)},
    );
    if (parties.isEmpty) return const NobodyCouldBeMoved();

    final free = await tx.execute(
      Sql.named('''
        SELECT seat_label, fare_minor, currency FROM seats
         WHERE departure_id = @id AND state = 'available'
         ORDER BY seat_label
           FOR UPDATE
      '''),
      parameters: {'id': TypedValue(Type.uuid, to)},
    );

    final plan = allocateRebooking(
      parties: [
        for (final r in parties)
          PartyToMove(
            bookingId: r.toColumnMap()['id'].toString(),
            seats: r.toColumnMap()['seats'] as int,
            bookedAt: r.toColumnMap()['created_at'] as DateTime,
          ),
      ],
      seatsAvailable: free.length,
    );
    // Partial coverage is a success — "18 / 42" is what a dispatcher acts on.
    // Nobody at all is not, and saying so is what sends them to find another
    // company rather than believing this one is handled.
    if (plan.moved.isEmpty) return const NobodyCouldBeMoved();

    final labels = [
      for (final r in free) r.toColumnMap()['seat_label'] as String,
    ];
    final currency =
        Currency.byCode(free.first.toColumnMap()['currency'] as String) ??
        Currency.xaf;

    var seatsMoved = 0;
    var rebillMinor = 0;
    final movedIds = <String>[];
    var next = 0;

    for (final party in plan.moved) {
      final taking = labels.sublist(next, next + party.seats);
      final fares = [
        for (var i = next; i < next + party.seats; i++)
          free[i].toColumnMap()['fare_minor'] as int,
      ];
      next += party.seats;

      // **The new seats are taken before a single old one is released**
      // (§2.4). Atomic either way; the ordering is what keeps a paid
      // passenger from ever existing without a seat on any coach at all.
      for (final label in taking) {
        final claimed = await tx.execute(
          Sql.named('''
            UPDATE seats
               SET state = 'sold', booking_id = @booking,
                   hold_id = NULL, held_until = NULL
             WHERE departure_id = @departure AND seat_label = @label
               AND state = 'available'
            RETURNING seat_label
          '''),
          parameters: {
            'departure': TypedValue(Type.uuid, to),
            'label': TypedValue(Type.text, label),
            'booking': TypedValue(Type.uuid, party.bookingId),
          },
        );
        if (claimed.isEmpty) {
          throw StateError('seat $label on $to vanished under a lock');
        }
      }

      final seated = await tx.execute(
        Sql.named('''
          SELECT seat_label, passenger_name, passenger_phone,
                 passenger_id_number, fare_minor
            FROM booking_seats
           WHERE booking_id = @id
           ORDER BY seat_label
        '''),
        parameters: {'id': TypedValue(Type.uuid, party.bookingId)},
      );

      await tx.execute(
        Sql.named('DELETE FROM booking_seats WHERE booking_id = @id'),
        parameters: {'id': TypedValue(Type.uuid, party.bookingId)},
        ignoreRows: true,
      );

      for (var i = 0; i < seated.length; i++) {
        final passenger = seated[i].toColumnMap();
        await tx.execute(
          Sql.named('''
            INSERT INTO booking_seats
              (booking_id, seat_label, passenger_name, passenger_phone,
               passenger_id_number, fare_minor)
            VALUES (@booking, @label, @name, @phone, @idNumber, @fare)
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, party.bookingId),
            'label': TypedValue(Type.text, taking[i]),
            'name': TypedValue(Type.text, passenger['passenger_name']),
            'phone': TypedValue(Type.text, passenger['passenger_phone']),
            'idNumber': TypedValue(Type.text, passenger['passenger_id_number']),
            // What they paid, carried across unchanged — onto another
            // company's dearer coach as readily as onto a cheaper one. An
            // involuntary change never costs a fare difference (ADR-0016),
            // and the difference is settled between the two operators rather
            // than with the passenger.
            'fare': TypedValue(Type.bigInteger, passenger['fare_minor']),
          },
          ignoreRows: true,
        );
      }

      await tx.execute(
        Sql.named('''
          UPDATE seats
             SET state = 'available', booking_id = NULL,
                 hold_id = NULL, held_until = NULL
           WHERE departure_id = @departure AND booking_id = @booking
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, from),
          'booking': TypedValue(Type.uuid, party.bookingId),
        },
        ignoreRows: true,
      );

      // The booking changes hands. This is the line that makes it protection
      // rather than a rebooking: the passenger is the receiving operator's to
      // carry now, and their manifest, their conductor's scanner and their
      // statement all have to agree about that.
      await tx.execute(
        Sql.named('''
          UPDATE bookings
             SET departure_id = @to, operator_id = @receiving,
                 involuntary_change = TRUE
           WHERE id = @id
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, party.bookingId),
          'to': TypedValue(Type.uuid, to),
          'receiving': TypedValue(Type.uuid, receiving),
        },
        ignoreRows: true,
      );

      seatsMoved += party.seats;
      for (final fare in fares) {
        // The rebill is on the **receiving** operator's public fare — the
        // seat they gave up — less the agreed discount. Not on what the
        // stranded passenger paid: the sending operator's pricing is none of
        // their business, and a rescuer with dearer seats should not be paid
        // less for giving one up.
        rebillMinor += Money(
          fare,
          currency,
        ).percentBps(10000 - (row['discount_bps']! as int)).minor;
      }
      movedIds.add(party.bookingId);
    }

    await _reissueUnder(tx, movedIds, to, receiving);

    // The settlement (§5): one payable against the other, no commission and
    // no cash. It nets into whichever payout run comes next, which is what
    // "règlement via BilletEnLigne, mensuel" means in the ledger.
    final rebill = Money(rebillMinor, currency);
    String? txnId;
    if (rebill.minor > 0) {
      final posting = protectionSettled(
        sendingOperatorId: sending,
        receivingOperatorId: receiving,
        amount: rebill,
        reference: requestId,
      );
      if (posting case Ok(:final value)) {
        txnId = await _postLedger(tx, value);
      }
    }

    await tx.execute(
      Sql.named('''
        INSERT INTO protection_movements
          (agreement_id, sending_operator_id, receiving_operator_id,
           disruption_id, departure_id, seats, rebill_minor, currency, txn_id)
        SELECT q.agreement_id, q.sending_operator_id, q.receiving_operator_id,
               q.disruption_id, q.to_departure_id, @seats, @rebill, @currency,
               @txn
          FROM protection_requests q WHERE q.id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, requestId),
        'seats': TypedValue(Type.integer, seatsMoved),
        'rebill': TypedValue(Type.bigInteger, rebillMinor),
        'currency': TypedValue(Type.text, currency.code),
        'txn': TypedValue(Type.uuid, txnId),
      },
      ignoreRows: true,
    );

    await tx.execute(
      Sql.named('''
        UPDATE protection_requests
           SET state = 'applied', decided_at = now(), applied_at = now(),
               decided_by_user = @actor, auto_accepted = @auto,
               seats_moved = @seats
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, requestId),
        'actor': TypedValue(Type.uuid, autoAccepted ? null : actorUserId),
        'auto': TypedValue(Type.boolean, autoAccepted),
        'seats': TypedValue(Type.integer, seatsMoved),
      },
      ignoreRows: true,
    );

    // One message per passenger, from the outbox, never inline with this
    // request (ADR-0019). The company name on their ticket has changed, which
    // is the single most alarming thing that can happen to a ticket without
    // warning.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        SELECT 'booking', b.id, 'booking.protected',
               jsonb_build_object('bookingId', b.id::text,
                                  'fromDepartureId', @from::text),
               'booking.protected:' || @from::text || ':' || b.id::text
          FROM bookings b
         WHERE b.id = ANY(@ids)
        ON CONFLICT (dedupe_key) DO NOTHING
      '''),
      parameters: {
        'from': TypedValue(Type.uuid, from),
        'ids': TypedValue(Type.uuidArray, movedIds),
      },
      ignoreRows: true,
    );

    await tx.execute(
      Sql.named('''
        INSERT INTO audit_log
          (actor_id, actor_type, action, subject_type, subject_id,
           operator_id, after_state)
        VALUES (@actor, 'operator_staff', 'protection.applied',
                'protection_request', @id, @operator, @after)
      '''),
      parameters: {
        'actor': TypedValue(Type.uuid, actorUserId),
        'id': TypedValue(Type.text, requestId),
        'operator': TypedValue(Type.uuid, receiving),
        'after': TypedValue(Type.jsonb, {
          'seatsMoved': seatsMoved,
          'passengersLeft': plan.passengersLeft,
          'rebillMinor': rebillMinor,
          'currency': currency.code,
          'autoAccepted': autoAccepted,
        }),
      },
      ignoreRows: true,
    );

    return null;
  });

  /// Re-signs every moved ticket under the **receiving** operator's code.
  ///
  /// The QR carries the operator as well as the departure and the seat
  /// (ADR-0007). A ticket still naming the company whose coach broke down
  /// scans as somebody else's passenger at the receiving conductor's door.
  Future<void> _reissueUnder(
    TxSession tx,
    List<String> bookingIds,
    String departureId,
    String operatorId,
  ) async {
    final issuer = _issuer;
    if (bookingIds.isEmpty || issuer == null) return;

    for (final bookingId in bookingIds) {
      final rows = await tx.execute(
        Sql.named('''
          SELECT b.ref, bs.seat_label, bs.passenger_name,
                 d.departs_at, r.code AS route_code, o.code AS operator_code
            FROM bookings b
            JOIN booking_seats bs ON bs.booking_id = b.id
            JOIN departures d ON d.id = b.departure_id
            JOIN routes r ON r.id = d.route_id
            JOIN operators o ON o.id = b.operator_id
           WHERE b.id = @id
           ORDER BY bs.seat_label
        '''),
        parameters: {'id': TypedValue(Type.uuid, bookingId)},
      );
      if (rows.isEmpty) continue;

      final first = rows.first.toColumnMap();
      final signed = await issuer.issue(
        bookingRef: BookingRef.trusted(first['ref'] as String),
        departureId: departureId,
        departsAt: first['departs_at'] as DateTime,
        routeCode: first['route_code'] as String,
        operatorCode: first['operator_code'] as String,
        seats: [
          for (final row in rows)
            (
              seatLabel: row.toColumnMap()['seat_label'] as String,
              passengerName: row.toColumnMap()['passenger_name'] as String,
            ),
        ],
      );

      // Replaced rather than added to. Two live tickets for one booking is
      // two people boarding on one fare.
      await tx.execute(
        Sql.named('DELETE FROM tickets WHERE booking_id = @id'),
        parameters: {'id': TypedValue(Type.uuid, bookingId)},
        ignoreRows: true,
      );

      for (final ticket in signed) {
        await tx.execute(
          Sql.named('''
            INSERT INTO tickets
              (booking_id, operator_id, departure_id, seat_label,
               payload, signature, key_id, rotating_secret)
            VALUES (@booking, @operator, @departure, @seat,
                    @payload, @signature, @keyId, @secret)
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, bookingId),
            'operator': TypedValue(Type.uuid, operatorId),
            'departure': TypedValue(Type.uuid, departureId),
            'seat': TypedValue(Type.text, ticket.seatLabel),
            'payload': TypedValue(Type.text, ticket.payload),
            'signature': TypedValue(Type.byteArray, ticket.signature),
            'keyId': TypedValue(Type.integer, ticket.keyId),
            'secret': TypedValue(Type.byteArray, ticket.rotatingSecret),
          },
          ignoreRows: true,
        );
      }
    }
  }

  Future<String> _postLedger(TxSession tx, LedgerTransaction txn) async {
    final created = await tx.execute(
      Sql.named('SELECT gen_random_uuid()::text AS id'),
    );
    final txnId = created.first.toColumnMap()['id']! as String;

    for (final entry in txn.entries) {
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
          'operator': TypedValue(Type.uuid, entry.operatorId),
          'memo': TypedValue(Type.text, entry.memo),
        },
        ignoreRows: true,
      );
    }
    return txnId;
  }

  /// The live agreement between two operators, with this month's usage.
  Future<ProtectionAgreementView?> _liveAgreement(
    TxSession tx,
    String me,
    String them,
  ) async {
    final (a, b) = ProtectionAgreement.partiesOf(me, them);
    final rows = await tx.execute(
      Sql.named('''
        SELECT $_columns,
               CASE WHEN a.operator_a = @me THEN a.operator_b
                    ELSE a.operator_a END ::text AS counterparty_id
          FROM protection_agreements a
         WHERE a.operator_a = @a AND a.operator_b = @b AND a.state = 'active'
      '''),
      parameters: {
        'a': TypedValue(Type.uuid, a),
        'b': TypedValue(Type.uuid, b),
        'me': TypedValue(Type.uuid, me),
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.first.toColumnMap();
    final id = row['id']! as String;

    final corridors = await tx.execute(
      Sql.named('''
        SELECT city_low, city_high FROM protection_corridors
         WHERE agreement_id = @id ORDER BY city_low, city_high
      '''),
      parameters: {'id': TypedValue(Type.uuid, id)},
    );

    return _view(
      row,
      me: me,
      corridors: [
        for (final c in corridors)
          Corridor(
            c.toColumnMap()['city_low']! as String,
            c.toColumnMap()['city_high']! as String,
          ),
      ],
      names: const {},
      used: await _usedThisMonth(tx, [id]),
    );
  }

  ProtectionRequestView _request(
    Map<String, dynamic> row,
    String me,
    Map<String, String> names,
  ) {
    final counterpartyId =
        row['counterparty_id'] as String? ??
        (row['sending_operator_id'] == me
            ? row['receiving_operator_id']! as String
            : row['sending_operator_id']! as String);

    final fare = row['replacement_fare_minor'];
    final discount = row['discount_bps'];
    final currency = row['replacement_currency'] == null
        ? Currency.xaf
        : Currency.byCode(row['replacement_currency'] as String) ??
              Currency.xaf;

    return ProtectionRequestView(
      id: row['id']! as String,
      agreementId: row['agreement_id']! as String,
      sendingOperatorId: row['sending_operator_id']! as String,
      receivingOperatorId: row['receiving_operator_id']! as String,
      counterpartyName: names[counterpartyId] ?? counterpartyId,
      weAsked: row['sending_operator_id'] == me,
      fromDepartureId: row['from_departure_id']! as String,
      toDepartureId: row['to_departure_id']! as String,
      seatsRequested: row['seats_requested']! as int,
      state: row['state']! as String,
      requestedAt: row['requested_at']! as DateTime,
      note: row['note'] as String?,
      routeCode: row['route_code'] as String?,
      departsAt: row['departs_at'] as DateTime?,
      replacementDepartsAt: row['replacement_departs_at'] as DateTime?,
      seatsFree: row['seats_free'] as int? ?? 0,
      // What the receiving operator would be paid for the seats being asked
      // for, at the agreed discount. Shown before the decision, not after.
      rebill: fare is int && discount is int
          ? Money(fare, currency)
                .percentBps(10000 - discount)
                .multiply(row['seats_requested']! as int)
          : null,
      autoAccepted: row['auto_accepted'] as bool? ?? false,
      seatsMoved: row['seats_moved'] as int?,
      declineReason: row['decline_reason'] as String?,
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

/// Wraps a re-accommodation refusal so a protection route reports it in the
/// same vocabulary the rebooking wave uses. The codes are the domain's rather
/// than a second set invented at the boundary.
final class _RebookingAsFailure extends DomainFailure {
  const _RebookingAsFailure(this.refusal);
  final RebookingRefusal refusal;
  @override
  String get code => refusal.code;
}
