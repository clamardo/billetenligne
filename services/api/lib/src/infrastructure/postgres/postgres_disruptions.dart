import 'package:bel_domain/bel_domain.dart';
import 'package:bel_domain/bel_domain.dart' as domain;
import 'package:postgres/postgres.dart' hide Result;

import '../../application/ports/disruption_desk.dart';
import '../../application/ports/ticket_issuer.dart';
import '../db/database.dart';
import 'postgres_operator_console.dart';

/// Declaring a disruption, on the tenant surface.
///
/// The whole method is one transaction, and the ordering inside it is the
/// design: record, supersede, restate the departure, mark the bookings, queue
/// the messages. A crash anywhere rolls back to a coach that is merely late
/// and nobody told — which is the situation we are already in today, and is
/// strictly better than half of a re-accommodation.
final class PostgresDisruptions implements DisruptionDesk {
  const PostgresDisruptions(this._db, {TicketIssuer? issuer})
    : _issuer = issuer;

  final Database _db;

  /// Needed only by the rescue coach, which re-signs the tickets whose seat
  /// changed. Optional so the read paths and the declaration path can be
  /// built without a signing key — a desk that could not declare a breakdown
  /// because no key was configured would fail at the worst moment.
  final TicketIssuer? _issuer;

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
  Future<Result<RescueApplied, DeclarationRefusal>> assignRescueCoach({
    required String operatorId,
    required String departureId,
    required String vehicleId,
    required String actorUserId,
    required DateTime now,
    String? note,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final found = await tx.execute(
      Sql.named('''
        SELECT d.departs_at, d.status::text AS status, d.fare_minor,
               d.currency::text AS currency, d.route_id,
               l.sections, l.blocked, l.mode
          FROM departures d
          JOIN seat_layouts l ON l.id = d.seat_layout_id
         WHERE d.id = @id AND d.operator_id = @operator
           FOR UPDATE OF d
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    if (found.isEmpty) return const Err(UnknownDeparture());
    final departure = found.first.toColumnMap();
    if (departure['status'] == 'arrived') {
      return const Err(DepartureAlreadyArrived());
    }

    final coach = await tx.execute(
      Sql.named('''
        SELECT v.registration, v.seat_layout_id,
               l.sections, l.blocked, l.mode
          FROM vehicles v
          JOIN seat_layouts l ON l.id = v.seat_layout_id
         WHERE v.id = @id AND v.operator_id = @operator
           AND v.status = 'active'
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, vehicleId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    // A coach that is off the road, blocked for compliance, or somebody
    // else's is not a rescue. One answer for all three.
    if (coach.isEmpty) return const Err(UnusableVehicle());
    final rescue = coach.first.toColumnMap();

    final oldLayout = PostgresOperatorConsole.decodeLayout(departure);
    final newLayout = PostgresOperatorConsole.decodeLayout(rescue);

    // Occupied means "has a booking behind it" — sold, or held against a
    // reservation somebody is on their way to pay for. A plain hold is
    // somebody mid-checkout and is released below.
    final taken = await tx.execute(
      Sql.named('''
        SELECT seat_label, state::text AS state, booking_id, held_until
          FROM seats
         WHERE departure_id = @id AND booking_id IS NOT NULL
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );

    final occupied = [
      for (final row in taken) row.toColumnMap()['seat_label'] as String,
    ];

    final remap = remapSeats(
      from: oldLayout,
      to: newLayout,
      occupied: occupied,
    );

    if (!remap.seatsEverybody) {
      return Err(CannotSeatEverybody(remap.unplaceable.length));
    }

    // Holds with nothing behind them go back. Their seats may not exist on
    // the new coach, and moving somebody's held seat under them mid-checkout
    // is worse than telling them to choose again.
    final released = await tx.execute(
      Sql.named('''
        UPDATE holds
           SET state = 'released'
         WHERE departure_id = @id AND state = 'active'
           AND NOT EXISTS (
             SELECT 1 FROM bookings b WHERE b.hold_id = holds.id
           )
        RETURNING id
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
      queryMode: QueryMode.extended,
    );

    // The seat rows are rebuilt from the new coach's layout rather than
    // renamed, because the new coach has different seats — different
    // sections, different fares, possibly different blocked ones.
    await tx.execute(
      Sql.named('DELETE FROM seats WHERE departure_id = @id'),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
      ignoreRows: true,
    );

    final currency = Currency.byCode((departure['currency'] as String).trim())!;
    final baseFare = Money(departure['fare_minor'] as int, currency);

    for (final label in newLayout.allSeatLabels()) {
      if (newLayout.blocked.contains(label)) continue;
      final fare = newLayout.fareFor(label, baseFare);
      await tx.execute(
        Sql.named('''
          INSERT INTO seats (departure_id, seat_label, operator_id,
                             section_code, fare_minor, currency)
          VALUES (@departure, @label, @operator, @section, @fare, @currency)
          ON CONFLICT (departure_id, seat_label) DO NOTHING
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'label': TypedValue(Type.text, label),
          'operator': TypedValue(Type.uuid, operatorId),
          'section': TypedValue(
            Type.text,
            newLayout.sectionForSeat(label)?.code ?? 'STD',
          ),
          'fare': TypedValue(Type.bigInteger, fare.minor),
          'currency': TypedValue(Type.text, fare.currency.code),
        },
        ignoreRows: true,
      );
    }

    // Everybody back into their seat. The state travels with them: a
    // reservation that was held stays held with its own deadline, a paid seat
    // stays sold. Flattening the two here would either sell an unpaid seat or
    // put a paid one back on sale.
    final movedBookings = <String>{};
    for (final row in taken) {
      final r = row.toColumnMap();
      final from = r['seat_label'] as String;
      final to = remap.destinationOf(from)!;
      final bookingId = r['booking_id'].toString();

      await tx.execute(
        Sql.named('''
          UPDATE seats
             SET state = @state::seat_state, booking_id = @booking,
                 held_until = @until
           WHERE departure_id = @departure AND seat_label = @label
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'label': TypedValue(Type.text, to),
          'state': TypedValue(Type.text, r['state'] as String),
          'booking': TypedValue(Type.uuid, bookingId),
          'until': TypedValue(
            Type.timestampWithTimezone,
            r['held_until'] as DateTime?,
          ),
        },
        ignoreRows: true,
      );

      if (from == to) continue;
      movedBookings.add(bookingId);

      await tx.execute(
        Sql.named('''
          UPDATE booking_seats SET seat_label = @to
           WHERE booking_id = @booking AND seat_label = @from
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'from': TypedValue(Type.text, from),
          'to': TypedValue(Type.text, to),
        },
        ignoreRows: true,
      );
    }

    await tx.execute(
      Sql.named('''
        UPDATE departures
           SET vehicle_id = @vehicle, seat_layout_id = @layout,
               capacity = @capacity
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'vehicle': TypedValue(Type.uuid, vehicleId),
        'layout': TypedValue(Type.uuid, rescue['seat_layout_id'].toString()),
        'capacity': TypedValue(Type.integer, newLayout.capacity),
      },
      ignoreRows: true,
    );

    final reissued = await _reissue(tx, movedBookings, departureId, operatorId);

    // The swap is itself a disruption: it supersedes the breakdown that
    // caused it, so "what is happening to my coach right now?" answers with
    // the resolution rather than with the problem.
    final declared = domain.declareDisruption(
      kind: DisruptionKind.equipmentSwap,
      cause: DisruptionCause.mechanical,
      departsAt: departure['departs_at'] as DateTime,
      now: now,
      note: note,
    );
    final disruption = declared.valueOrNull!;

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
          (operator_id, departure_id, kind, cause, note, marks_involuntary,
           bookings_affected, declared_by, declared_at)
        VALUES (@operator, @departure, 'equipment_swap', 'mechanical', @note,
                TRUE, @affected, @actor, @now)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'departure': TypedValue(Type.uuid, departureId),
        'note': TypedValue(Type.text, disruption.note),
        'affected': TypedValue(Type.integer, taken.length),
        'actor': TypedValue(Type.uuid, actorUserId),
        'now': TypedValue(Type.timestampWithTimezone, now),
      },
    );
    final disruptionId = inserted.first.toColumnMap()['id'].toString();

    for (final row in superseded) {
      await tx.execute(
        Sql.named(
          'UPDATE disruptions SET superseded_by = @new WHERE id = @old',
        ),
        parameters: {
          'new': TypedValue(Type.uuid, disruptionId),
          'old': TypedValue(Type.uuid, row.toColumnMap()['id'].toString()),
        },
        ignoreRows: true,
      );
    }

    await tx.execute(
      Sql.named('''
        UPDATE bookings SET involuntary_change = TRUE
         WHERE departure_id = @id AND state IN ('confirmed', 'pending_payment')
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
      ignoreRows: true,
    );

    // A different event type from a declaration, and a different sentence:
    // this one carries the seat, because "votre place est déjà réservée,
    // siège 14A" is what turns an anxious passenger into a calm one (§3.1).
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        SELECT 'disruption', b.id, 'disruption.resolved',
               jsonb_build_object('bookingId', b.id::text,
                                  'disruptionId', @id::text),
               'disruption.resolved:' || @id::text || ':' || b.id::text
          FROM bookings b
         WHERE b.departure_id = @departure
           AND b.state IN ('confirmed', 'pending_payment')
        ON CONFLICT (dedupe_key) DO NOTHING
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, disruptionId),
        'departure': TypedValue(Type.uuid, departureId),
      },
      ignoreRows: true,
    );

    await tx.execute(
      Sql.named('''
        INSERT INTO audit_log
          (actor_id, actor_type, action, subject_type, subject_id,
           operator_id, reason, after_state)
        VALUES (@actor, 'operator_staff', 'disruption.rescue', 'departure',
                @departure, @operator, @reason, @after)
      '''),
      parameters: {
        'actor': TypedValue(Type.uuid, actorUserId),
        'departure': TypedValue(Type.text, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
        'reason': TypedValue(
          Type.text,
          note == null
              ? 'rescue coach ${rescue['registration']}'
              : 'rescue coach ${rescue['registration']}: $note',
        ),
        'after': TypedValue(Type.jsonb, {
          'vehicleId': vehicleId,
          'registration': rescue['registration'],
          'seatsMoved': remap.movedCount,
          'ticketsReissued': reissued,
        }),
      },
      ignoreRows: true,
    );

    return Ok(
      RescueApplied(
        disruptionId: disruptionId,
        departureId: departureId,
        registration: rescue['registration'] as String,
        remap: remap,
        passengersTold: taken.length,
        ticketsReissued: reissued,
        holdsReleased: released.length,
      ),
    );
  });

  /// Re-signs the tickets of the bookings whose seats actually changed.
  ///
  /// The seat is inside the signed payload, so a moved passenger with an old
  /// ticket scans as somebody else's seat at the door. An unmoved passenger
  /// is left alone on purpose: their QR still says the truth, and reissuing
  /// it would break the screenshot they already sent to whoever is meeting
  /// them.
  Future<int> _reissue(
    TxSession tx,
    Set<String> bookingIds,
    String departureId,
    String operatorId,
  ) async {
    if (bookingIds.isEmpty || _issuer == null) return 0;

    var reissued = 0;
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
      final signed = await _issuer.issue(
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
      // two people boarding on one fare, and `redemptions` would let the
      // second through because it is a different ticket id.
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
        reissued++;
      }
    }
    return reissued;
  }

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
