import 'package:bel_api/src/application/ports/reschedule_desk.dart';
import 'package:bel_api/src/application/ports/ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

/// Rescheduling, against Postgres (`01-feature-spec.md` §8.1).
///
/// The same two-scope shape as every other traveller-initiated movement:
/// **reading runs as them**, because the alternatives are the departure and
/// seat rows anybody searching the route can already see; **moving
/// escalates**, because it writes the operator's seats, manifest and tickets.
///
/// One rule decides the ordering inside the escalated transaction and it is
/// the same one the rebooking wave follows: **the new seats are taken before
/// a single old one is released.** The transaction makes it atomic either
/// way; the ordering is what stops a paid passenger existing without a seat
/// on any coach at all, including in the middle of a raise.
final class PostgresReschedules implements RescheduleDesk {
  PostgresReschedules(this._db, {TicketIssuer? issuer, Duration? horizon})
    : _issuer = issuer,
      _horizon = horizon ?? const Duration(days: 7);

  final Database _db;
  final TicketIssuer? _issuer;

  /// How far ahead alternatives are offered. A week, because a change is a
  /// plan somebody has already made — unlike a breakdown, where §3.2's
  /// 36 hours is the span of the disruption itself.
  final Duration _horizon;

  @override
  Future<ChangeOptions?> options({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final row = await _booking(tx, bookingRef);
    if (row == null) return null;
    return _optionsFrom(tx, row, now);
  });

  @override
  Future<({ChangeApplied? applied, ChangeRefusal? refusal})?> change({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  }) async {
    // As themselves first, and before any privilege is taken.
    final seen = await _db.transaction(DbScope.traveller(userId), (tx) async {
      final row = await _booking(tx, bookingRef);
      return row == null
          ? null
          : (id: row['id'].toString(), ref: row['ref'] as String);
    });
    if (seen == null) return null;

    return _move(
      bookingId: seen.id,
      ref: seen.ref,
      userId: userId,
      toDepartureId: toDepartureId,
      now: now,
    );
  }

  Future<Map<String, Object?>?> _booking(TxSession tx, String ref) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.ref, b.state::text AS state, b.involuntary_change,
               b.fare_minor, b.currency, b.departure_id::text AS departure_id,
               b.operator_id::text AS operator_id,
               d.departs_at, d.route_id::text AS route_id,
               r.origin_city, r.destination_city,
               (SELECT count(*) FROM booking_seats s WHERE s.booking_id = b.id)
                 AS seat_count,
               p.change_free_hours, p.change_fee_bps, p.change_cutoff_hours
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          JOIN routes r ON r.id = d.route_id
          LEFT JOIN refund_policies p
                 ON p.id = b.refund_policy_id
                AND p.version = b.refund_policy_version
         WHERE upper(b.ref) = upper(@ref)
      '''),
      parameters: {'ref': TypedValue(Type.text, ref.trim())},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  static ChangePolicy _policyFrom(Map<String, Object?> row) => ChangePolicy(
    // D-08's own numbers for a booking sold before the operator wrote any
    // terms. Not a fallback picked here: the column defaults are the same
    // three, and this line is what keeps a NULL join from inventing a fourth.
    freeBefore: Duration(hours: row['change_free_hours'] as int? ?? 24),
    feeBps: row['change_fee_bps'] as int? ?? 1000,
    cutoff: Duration(hours: row['change_cutoff_hours'] as int? ?? 2),
  );

  Future<ChangeOptions> _optionsFrom(
    TxSession tx,
    Map<String, Object?> row,
    DateTime now,
  ) async {
    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final paidFare = Money(row['fare_minor'] as int, currency);
    final departsAt = row['departs_at']! as DateTime;
    final policy = _policyFrom(row);
    final seatsNeeded = (row['seat_count'] as int?) ?? 1;
    final involuntary = row['involuntary_change'] as bool? ?? false;

    ChangeOptions shell({
      List<ChangeOption> options = const [],
      ChangeRefusal? refusal,
    }) => ChangeOptions(
      bookingRef: row['ref'] as String,
      originCity: row['origin_city'] as String,
      destinationCity: row['destination_city'] as String,
      seatsNeeded: seatsNeeded,
      currentDepartureId: row['departure_id']! as String,
      currentDepartsAt: departsAt,
      paidFare: paidFare,
      policy: policy,
      options: options,
      involuntary: involuntary,
      refusal: refusal,
    );

    // A booking that is not paid for has nothing to move. It is cancelled and
    // bought again, which costs the traveller nothing and keeps one meaning
    // for "change".
    if (row['state'] != 'confirmed') {
      return shell(refusal: const ChangeAfterDeparture());
    }

    // The window, once, before any row is priced: "vous ne pouvez plus
    // changer" is one sentence, and repeating it on eight rows is noise.
    final gate = quoteChange(
      paidFare: paidFare,
      newFare: paidFare,
      departsAt: departsAt,
      targetDepartsAt: departsAt.add(const Duration(minutes: 1)),
      now: now,
      policy: policy,
      involuntary: involuntary,
    );
    if (gate.valueOrNull == null) {
      return shell(refusal: gate.failureOrNull);
    }

    final candidates = await tx.execute(
      Sql.named('''
        SELECT d.id::text AS id, d.departs_at, d.arrives_at, d.fare_minor,
               (SELECT count(*) FROM seats s
                 WHERE s.departure_id = d.id
                   AND (s.state = 'available'
                        OR (s.state = 'held' AND s.held_until < now())))
                 AS free
          FROM departures d
         WHERE d.route_id = @route
           AND d.operator_id = @operator
           AND d.id <> @current
           AND d.status = 'scheduled'
           AND d.departs_at > now()
           AND d.departs_at < now() + make_interval(secs => @horizon)
         ORDER BY d.departs_at
         LIMIT 20
      '''),
      parameters: {
        'route': TypedValue(Type.uuid, row['route_id']! as String),
        'operator': TypedValue(Type.uuid, row['operator_id']! as String),
        'current': TypedValue(Type.uuid, row['departure_id']! as String),
        'horizon': TypedValue(Type.double, _horizon.inSeconds.toDouble()),
      },
    );

    final options = <ChangeOption>[];
    for (final candidate in candidates) {
      final c = candidate.toColumnMap();
      final free = (c['free'] as int?) ?? 0;
      final fare = Money(c['fare_minor'] as int, currency);

      final quoted = quoteChange(
        paidFare: paidFare,
        newFare: fare,
        departsAt: departsAt,
        targetDepartsAt: c['departs_at']! as DateTime,
        now: now,
        policy: policy,
        involuntary: involuntary,
      );

      options.add(
        ChangeOption(
          departureId: c['id']! as String,
          departsAt: c['departs_at']! as DateTime,
          arrivesAt: c['arrives_at']! as DateTime,
          fare: fare,
          seatsAvailable: free,
          quote: quoted.valueOrNull,
          // A full coach is shown with the reason rather than dropped: a
          // departure missing from a list is a departure somebody telephones
          // an agency to ask about.
          refusal:
              quoted.failureOrNull ??
              (free < seatsNeeded ? ChangeDoesNotFit(seatsNeeded, free) : null),
        ),
      );
    }

    return shell(options: options);
  }

  /// The escalated half. Everything the screen was drawn from is re-read
  /// under the lock, because the coach can fill between the two.
  Future<({ChangeApplied? applied, ChangeRefusal? refusal})?> _move({
    required String bookingId,
    required String ref,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  }) => _db.transaction(DbScope.platform(userId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.purchaser_user_id::text AS purchaser, b.state::text AS state,
               b.involuntary_change, b.fare_minor, b.currency,
               b.operator_id::text AS operator_id,
               b.departure_id::text AS departure_id,
               d.departs_at, d.route_id::text AS route_id,
               (SELECT count(*) FROM booking_seats s WHERE s.booking_id = b.id)
                 AS seat_count,
               p.change_free_hours, p.change_fee_bps, p.change_cutoff_hours
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          LEFT JOIN refund_policies p
                 ON p.id = b.refund_policy_id
                AND p.version = b.refund_policy_version
         WHERE b.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    if (rows.isEmpty) return null;
    final row = rows.first.toColumnMap();

    // Still theirs. This transaction can write any operator's rows, so the
    // ownership the traveller-scoped read established is asserted again
    // rather than assumed to have survived the escalation.
    if (row['purchaser'] != userId) return null;
    if (row['state'] != 'confirmed') {
      return (applied: null, refusal: const ChangeAfterDeparture());
    }

    final fromDepartureId = row['departure_id']! as String;
    if (fromDepartureId == toDepartureId) {
      return (applied: null, refusal: const ChangeToTheSameDeparture());
    }

    // Both departures locked in id order. Two travellers moving in opposite
    // directions between the same pair of coaches is a deadlock on exactly
    // the morning it happens.
    final ids = [fromDepartureId, toDepartureId]..sort();
    await tx.execute(
      Sql.named(
        'SELECT id FROM departures WHERE id = ANY(@ids) ORDER BY id FOR UPDATE',
      ),
      parameters: {'ids': TypedValue(Type.uuidArray, ids)},
      ignoreRows: true,
    );

    final target = await tx.execute(
      Sql.named('''
        SELECT d.departs_at, d.fare_minor, d.status::text AS status,
               d.route_id::text AS route_id,
               d.operator_id::text AS operator_id
          FROM departures d WHERE d.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, toDepartureId)},
    );
    if (target.isEmpty) return (applied: null, refusal: const ChangeOffRoute());
    final to = target.first.toColumnMap();

    // Another company or another road is a purchase, not a change. Refused
    // here rather than filtered on the screen, because the screen is not
    // what the traveller's client has to send.
    if (to['operator_id'] != row['operator_id'] ||
        to['route_id'] != row['route_id'] ||
        to['status'] != 'scheduled') {
      return (applied: null, refusal: const ChangeOffRoute());
    }

    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final paidFare = Money(row['fare_minor'] as int, currency);

    final quoted = quoteChange(
      paidFare: paidFare,
      newFare: Money(to['fare_minor'] as int, currency),
      departsAt: row['departs_at']! as DateTime,
      targetDepartsAt: to['departs_at']! as DateTime,
      now: now,
      policy: _policyFrom(row),
      involuntary: row['involuntary_change'] as bool? ?? false,
    );
    if (quoted.valueOrNull == null) {
      return (applied: null, refusal: quoted.failureOrNull);
    }

    // Priced under the lock, and refused if anything is owed. The money has
    // to be settled before somebody boards a coach they have not paid for,
    // and collecting it here is a payment intent bound to a held-but-unapplied
    // change — its own slice. The amount travels with the refusal so the app
    // can say what to bring to the counter.
    final owed = quoted.valueOrNull!.owed;
    if (owed.minor > 0) {
      return (
        applied: null,
        refusal: ChangeMustBePaid(owed.minor, currency.code),
      );
    }

    final seatsNeeded = (row['seat_count'] as int?) ?? 1;
    final free = await tx.execute(
      Sql.named('''
        SELECT seat_label FROM seats
         WHERE departure_id = @id
           AND (state = 'available' OR (state = 'held' AND held_until < now()))
         ORDER BY seat_label
           FOR UPDATE
      '''),
      parameters: {'id': TypedValue(Type.uuid, toDepartureId)},
    );
    if (free.length < seatsNeeded) {
      return (
        applied: null,
        refusal: ChangeDoesNotFit(seatsNeeded, free.length),
      );
    }

    final taking = [
      for (var i = 0; i < seatsNeeded; i++)
        free[i].toColumnMap()['seat_label'] as String,
    ];

    // Taken before a single old one is released.
    for (final label in taking) {
      final claimed = await tx.execute(
        Sql.named('''
          UPDATE seats
             SET state = 'sold', booking_id = @booking,
                 hold_id = NULL, held_until = NULL
           WHERE departure_id = @departure AND seat_label = @label
             AND (state = 'available'
                  OR (state = 'held' AND held_until < now()))
          RETURNING seat_label
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, toDepartureId),
          'label': TypedValue(Type.text, label),
          'booking': TypedValue(Type.uuid, bookingId),
        },
      );
      if (claimed.isEmpty) {
        return (
          applied: null,
          refusal: ChangeDoesNotFit(seatsNeeded, taking.length - 1),
        );
      }
    }

    final seated = await tx.execute(
      Sql.named('''
        SELECT seat_label, passenger_name, passenger_phone,
               passenger_id_number, fare_minor
          FROM booking_seats WHERE booking_id = @id ORDER BY seat_label
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );

    await tx.execute(
      Sql.named('DELETE FROM booking_seats WHERE booking_id = @id'),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
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
          'booking': TypedValue(Type.uuid, bookingId),
          'label': TypedValue(Type.text, taking[i]),
          'name': TypedValue(Type.text, passenger['passenger_name']),
          'phone': TypedValue(Type.text, passenger['passenger_phone']),
          'idNumber': TypedValue(Type.text, passenger['passenger_id_number']),
          // What they paid, unchanged. Nothing is owed — the quote above
          // refused otherwise — so a cheaper coach does not rewrite the fare
          // downwards either, which is the sentence the row already carried.
          'fare': TypedValue(Type.bigInteger, passenger['fare_minor']),
        },
        ignoreRows: true,
      );
    }

    await tx.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'available', booking_id = NULL, hold_id = NULL,
               held_until = NULL
         WHERE departure_id = @departure AND booking_id = @booking
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, fromDepartureId),
        'booking': TypedValue(Type.uuid, bookingId),
      },
      ignoreRows: true,
    );

    await tx.execute(
      Sql.named('UPDATE bookings SET departure_id = @to WHERE id = @id'),
      parameters: {
        'id': TypedValue(Type.uuid, bookingId),
        'to': TypedValue(Type.uuid, toDepartureId),
      },
      ignoreRows: true,
    );

    // The QR carries the seat and the departure (ADR-0007), so a ticket left
    // alone would admit somebody to a seat the manifest has given away.
    await _reissue(tx, bookingId, toDepartureId, row['operator_id']! as String);

    // The same event the dispatcher's wave queues: from the passenger's side
    // it is the same fact — you are on the 14:00 now, here is the seat.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('booking', @booking, 'booking.rebooked',
                jsonb_build_object('bookingId', @booking::text,
                                   'fromDepartureId', @from::text),
                'booking.rebooked:' || @from::text || ':' || @booking::text)
        ON CONFLICT (dedupe_key) DO NOTHING
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'from': TypedValue(Type.uuid, fromDepartureId),
      },
      ignoreRows: true,
    );

    await tx.execute(
      Sql.named('''
        INSERT INTO audit_log
          (actor_id, actor_type, action, subject_type, subject_id,
           operator_id, after_state)
        VALUES (@actor, 'traveller', 'booking.self_changed', 'booking',
                @booking, @operator, @after)
      '''),
      parameters: {
        'actor': TypedValue(Type.uuid, userId),
        'booking': TypedValue(Type.text, bookingId),
        'operator': TypedValue(Type.uuid, row['operator_id']! as String),
        'after': TypedValue(Type.jsonb, {
          'toDepartureId': toDepartureId,
          'seats': taking,
        }),
      },
      ignoreRows: true,
    );

    return (
      applied: ChangeApplied(
        bookingRef: ref,
        departureId: toDepartureId,
        departsAt: to['departs_at']! as DateTime,
        seatLabels: taking,
      ),
      refusal: null,
    );
  });

  Future<void> _reissue(
    TxSession tx,
    String bookingId,
    String departureId,
    String operatorId,
  ) async {
    final issuer = _issuer;
    if (issuer == null) return;

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
    if (rows.isEmpty) return;

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

    // Replaced rather than added to: two live tickets for one booking is two
    // people boarding on one fare.
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
