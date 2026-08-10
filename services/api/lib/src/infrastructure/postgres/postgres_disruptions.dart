import 'package:bel_domain/bel_domain.dart';
import 'package:bel_domain/bel_domain.dart' as domain;
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/disruption_desk.dart';
import '../db/database.dart';

/// Declaring a disruption, on the tenant surface.
///
/// The whole method is one transaction, and the ordering inside it is the
/// design: record, supersede, restate the departure, mark the bookings, queue
/// the messages. A crash anywhere rolls back to a coach that is merely late
/// and nobody told — which is the situation we are already in today, and is
/// strictly better than half of a re-accommodation.
final class PostgresDisruptions implements DisruptionDesk {
  const PostgresDisruptions(this._db);

  final Database _db;

  @override
  Future<Result<DisruptionRecord, DeclarationRefusal>> declare({
    required String operatorId,
    required String departureId,
    required DisruptionKind kind,
    required DisruptionCause cause,
    required String actorUserId,
    required DateTime now,
    String? note,
    String? location,
    DateTime? revisedDepartsAt,
    DateTime? estimatedResolution,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // The departure is locked for the length of the declaration. Two
    // dispatchers on two phones at the same roadside is not hypothetical, and
    // without this both would supersede each other's disruption and both
    // would queue a message.
    final found = await tx.execute(
      Sql.named('''
        SELECT departs_at, status::text AS status
          FROM departures
         WHERE id = @id AND operator_id = @operator
           FOR UPDATE
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    if (found.isEmpty) return const Err(UnknownDeparture());

    final row = found.first.toColumnMap();
    if (row['status'] == 'arrived') {
      return const Err(DepartureAlreadyArrived());
    }

    final departsAt = row['departs_at'] as DateTime;

    // The same function the console called before the dispatcher confirmed.
    // A server that validated differently would refuse a declaration the app
    // had already shown as accepted, at the roadside, on 2G.
    final declared = domain.declareDisruption(
      kind: kind,
      cause: cause,
      departsAt: departsAt,
      now: now,
      note: note,
      location: location,
      revisedDepartsAt: revisedDepartsAt,
      estimatedResolution: estimatedResolution,
    );

    final Disruption disruption;
    switch (declared) {
      case Ok(:final value):
        disruption = value;
      case Err(:final failure):
        // Passed back with the domain's own code, so the console shows the
        // same sentence it would have shown had it been able to check
        // locally. It could not: the scheduled time is on the row above.
        return Err(DeclarationInvalid(failure));
    }

    final affected = await tx.execute(
      Sql.named('''
        SELECT count(*)::int AS n
          FROM bookings
         WHERE departure_id = @id AND state = 'confirmed'
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    final bookingsAffected = affected.first.first as int? ?? 0;

    // Superseded BEFORE the insert, because `disruptions_one_open` is a plain
    // unique index: two open rows on one departure never exist, not even for
    // the length of a statement. The chain is stitched up afterwards, by id.
    final superseded = await tx.execute(
      Sql.named('''
        UPDATE disruptions
           SET resolved_at = @now
         WHERE departure_id = @departure AND resolved_at IS NULL
        RETURNING id
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'now': TypedValue(Type.timestampWithTimezone, now),
      },
    );

    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO disruptions
          (operator_id, departure_id, kind, cause, note, location,
           revised_departs_at, estimated_resolution, marks_involuntary,
           bookings_affected, declared_by, declared_at)
        VALUES
          (@operator, @departure, @kind::disruption_kind, @cause, @note,
           @location, @revised, @resolution, @involuntary, @affected,
           @actor, @now)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'departure': TypedValue(Type.uuid, departureId),
        'kind': TypedValue(Type.text, _kindToColumn(kind)),
        'cause': TypedValue(Type.text, cause.name),
        'note': TypedValue(Type.text, disruption.note),
        'location': TypedValue(Type.text, disruption.location),
        'revised': TypedValue(Type.timestampWithTimezone, revisedDepartsAt),
        'resolution': TypedValue(
          Type.timestampWithTimezone,
          estimatedResolution,
        ),
        'involuntary': TypedValue(Type.boolean, disruption.marksInvoluntary),
        'affected': TypedValue(Type.integer, bookingsAffected),
        'actor': TypedValue(Type.uuid, actorUserId),
        'now': TypedValue(Type.timestampWithTimezone, now),
      },
    );

    final id = inserted.first.toColumnMap()['id'].toString();

    // A breakdown followed by an equipment swap is one story, and the link
    // is what lets a dispute be read forwards rather than guessed at from
    // timestamps.
    for (final row in superseded) {
      await tx.execute(
        Sql.named(
          'UPDATE disruptions SET superseded_by = @new WHERE id = @old',
        ),
        parameters: {
          'new': TypedValue(Type.uuid, id),
          'old': TypedValue(Type.uuid, row.toColumnMap()['id'].toString()),
        },
        ignoreRows: true,
      );
    }

    final status = disruption.departureStatus;
    if (status != null) {
      await tx.execute(
        Sql.named('''
          UPDATE departures
             SET status = @status::departure_status,
                 departs_at = COALESCE(@revised, departs_at)
           WHERE id = @id
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, departureId),
          'status': TypedValue(Type.text, status),
          // A delay moves the departure itself. The board, the manifest and
          // the conductor's app all read `departs_at`, and a "delayed" row
          // still showing 06:00 is a row that tells three surfaces the wrong
          // time.
          'revised': TypedValue(Type.timestampWithTimezone, revisedDepartsAt),
        },
        ignoreRows: true,
      );
    }

    if (disruption.marksInvoluntary) {
      // One-way. A booking that has been disrupted once keeps the exemption
      // even if the operator later resolves it, because the traveller made
      // decisions on the strength of it.
      await tx.execute(
        Sql.named('''
          UPDATE bookings
             SET involuntary_change = TRUE
           WHERE departure_id = @id
             AND state IN ('confirmed', 'pending_payment')
        '''),
        parameters: {'id': TypedValue(Type.uuid, departureId)},
        ignoreRows: true,
      );
    }

    // One row per booking rather than one per disruption: the drain composes
    // in each recipient's own language and sends to each recipient's own
    // address, and a single row would have to carry a list of both.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        SELECT 'disruption', b.id, 'disruption.declared',
               jsonb_build_object('bookingId', b.id::text,
                                  'disruptionId', @id::text),
               'disruption.declared:' || @id::text || ':' || b.id::text
          FROM bookings b
         WHERE b.departure_id = @departure
           AND b.state IN ('confirmed', 'pending_payment')
        ON CONFLICT (dedupe_key) DO NOTHING
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, id),
        'departure': TypedValue(Type.uuid, departureId),
      },
      ignoreRows: true,
    );

    // The operator's own trail. A dispatcher answering "who cancelled the
    // 06:00?" three weeks later has one place to look, and it is not a chat
    // message.
    await tx.execute(
      Sql.named('''
        INSERT INTO audit_log
          (actor_id, actor_type, action, subject_type, subject_id,
           operator_id, reason, after_state)
        VALUES (@actor, 'operator_staff', 'disruption.declare', 'departure',
                @departure, @operator, @reason, @after)
      '''),
      parameters: {
        'actor': TypedValue(Type.uuid, actorUserId),
        'departure': TypedValue(Type.text, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
        // The cause is the reason. A second free-text box on a roadside form
        // is a box that gets "x" typed into it.
        'reason': TypedValue(
          Type.text,
          disruption.note == null
              ? cause.name
              : '${cause.name}: ${disruption.note}',
        ),
        'after': TypedValue(Type.jsonb, {
          'disruptionId': id,
          'kind': kind.name,
          'bookingsAffected': bookingsAffected,
          'marksInvoluntary': disruption.marksInvoluntary,
        }),
      },
      ignoreRows: true,
    );

    return Ok(
      DisruptionRecord(
        id: id,
        departureId: departureId,
        disruption: disruption,
        marksInvoluntary: disruption.marksInvoluntary,
        bookingsAffected: bookingsAffected,
      ),
    );
  });

  @override
  Future<Map<String, DisruptionRecord>> openFor({
    required String operatorId,
    required DateTime from,
    required DateTime to,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT x.id, x.departure_id, x.kind::text AS kind, x.cause, x.note,
               x.location, x.revised_departs_at, x.estimated_resolution,
               x.marks_involuntary, x.bookings_affected, x.declared_at,
               d.departs_at
          FROM disruptions x
          JOIN departures d ON d.id = x.departure_id
         WHERE x.operator_id = @operator
           AND x.resolved_at IS NULL
           AND d.departs_at >= @from AND d.departs_at < @to
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.timestampWithTimezone, from),
        'to': TypedValue(Type.timestampWithTimezone, to),
      },
    );

    return {
      for (final r in rows)
        r.toColumnMap()['departure_id'].toString(): readDisruption(
          r.toColumnMap(),
        ),
    };
  });

  /// Row → record. Shared with the traveller's own read, which asks the same
  /// question from the public surface.
  static DisruptionRecord readDisruption(Map<String, dynamic> r) =>
      DisruptionRecord(
        id: r['id'].toString(),
        departureId: r['departure_id'].toString(),
        disruption: Disruption.stored(
          kind: kindFromColumn(r['kind'] as String),
          cause: causeFromColumn(r['cause'] as String),
          // The departure's own time, so `delay` is a difference this record
          // can state. A disruption read without it can only say "later".
          departsAt: r['departs_at'] as DateTime,
          declaredAt: r['declared_at'] as DateTime,
          note: r['note'] as String?,
          location: r['location'] as String?,
          revisedDepartsAt: r['revised_departs_at'] as DateTime?,
          estimatedResolution: r['estimated_resolution'] as DateTime?,
        ),
        marksInvoluntary: r['marks_involuntary'] as bool,
        bookingsAffected: r['bookings_affected'] as int? ?? 0,
        resolvedAt: r['resolved_at'] as DateTime?,
      );

  /// `breakdownEnRoute` ⇄ `breakdown_en_route`. The enum is Dart's naming and
  /// the type is SQL's, and translating in one place beats two vocabularies
  /// that drift.
  static String _kindToColumn(DisruptionKind kind) => switch (kind) {
    DisruptionKind.delay => 'delay',
    DisruptionKind.cancellation => 'cancellation',
    DisruptionKind.breakdownEnRoute => 'breakdown_en_route',
    DisruptionKind.equipmentSwap => 'equipment_swap',
    DisruptionKind.diversion => 'diversion',
    DisruptionKind.routeSuspension => 'route_suspension',
  };

  static DisruptionKind kindFromColumn(String value) => switch (value) {
    'delay' => DisruptionKind.delay,
    'cancellation' => DisruptionKind.cancellation,
    'breakdown_en_route' => DisruptionKind.breakdownEnRoute,
    'equipment_swap' => DisruptionKind.equipmentSwap,
    'diversion' => DisruptionKind.diversion,
    _ => DisruptionKind.routeSuspension,
  };

  static DisruptionCause causeFromColumn(String value) => DisruptionCause.values
      .firstWhere((c) => c.name == value, orElse: () => DisruptionCause.other);
}
