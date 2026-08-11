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

  /// How long a change order holds its seats. Longer than the ten-minute
  /// payment window (ADR-0005 rule 5), for the same reason a booking's hold
  /// is: a seat released while somebody is entering their PIN is the one
  /// outcome neither end can undo.
  static const _paymentWindow = Duration(minutes: 15);

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

    await _relocate(
      tx,
      bookingId: bookingId,
      fromDepartureId: fromDepartureId,
      toDepartureId: toDepartureId,
      taking: taking,
      operatorId: row['operator_id']! as String,
      userId: userId,
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

  @override
  Future<({ChangeOrder? order, ChangeRefusal? refusal})?> reserveChange({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  }) async {
    // As themselves first, exactly as `change` does: a stranger's reference
    // and one that was never issued must answer identically.
    final seen = await _db.transaction(DbScope.traveller(userId), (tx) async {
      final row = await _booking(tx, bookingRef);
      return row == null
          ? null
          : (id: row['id'].toString(), ref: row['ref'] as String);
    });
    if (seen == null) return null;

    return _reserve(
      bookingId: seen.id,
      ref: seen.ref,
      userId: userId,
      toDepartureId: toDepartureId,
      now: now,
    );
  }

  @override
  Future<ChangeOrder?> orderById({
    required String changeId,
    required String userId,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    // Read as them, so the row policy decides what is visible rather than a
    // WHERE clause somebody could forget to write.
    final rows = await tx.execute(
      Sql.named('''
        SELECT c.id::text AS id, c.booking_id::text AS booking_id, b.ref,
               c.to_departure_id::text AS to_departure_id, c.seat_labels,
               c.fee_minor, c.difference_minor, c.owed_minor,
               c.currency::text AS currency, c.state::text AS state,
               c.expires_at, d.departs_at
          FROM booking_changes c
          JOIN bookings b ON b.id = c.booking_id
          JOIN departures d ON d.id = c.to_departure_id
         WHERE c.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
    );
    return rows.isEmpty ? null : _orderFrom(rows.first.toColumnMap());
  });

  @override
  Future<ChangeApplied?> applyPaidChange({
    required String changeId,
    required String intentId,
    required LedgerTransaction posting,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT c.id::text AS id, c.booking_id::text AS booking_id,
               c.operator_id::text AS operator_id,
               c.to_departure_id::text AS to_departure_id,
               c.seat_labels, c.state::text AS state,
               c.created_by::text AS created_by,
               b.ref, b.departure_id::text AS departure_id,
               d.departs_at
          FROM booking_changes c
          JOIN bookings b ON b.id = c.booking_id
          JOIN departures d ON d.id = c.to_departure_id
         WHERE c.id = @id
           FOR UPDATE OF c
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
    );
    if (rows.isEmpty) return null;
    final row = rows.first.toColumnMap();

    final taking = [
      for (final label in (row['seat_labels'] as List? ?? const [])) '$label',
    ];
    final applied = ChangeApplied(
      bookingRef: row['ref'] as String,
      departureId: row['to_departure_id']! as String,
      departsAt: row['departs_at']! as DateTime,
      seatLabels: taking,
    );

    // Idempotent, and it has to be: a duplicate callback and a poll landing
    // together must move one booking once. An order already applied answers
    // with what it did rather than doing it twice.
    if (row['state'] == 'applied') return applied;
    if (row['state'] != 'awaiting_payment') return null;

    final bookingId = row['booking_id']! as String;
    final fromDepartureId = row['departure_id']! as String;
    final toDepartureId = row['to_departure_id']! as String;

    // The seats this order has been holding, turned into sold ones. Scoped to
    // the hold rather than to "whatever is free": between the order and the
    // capture the coach may have filled around them, and the only seats this
    // booking is entitled to are the ones it paid to keep.
    final claimed = await tx.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'sold', booking_id = @booking,
               hold_id = NULL, held_until = NULL
         WHERE departure_id = @departure
           AND seat_label = ANY(@labels)
           AND state = 'held'
           AND hold_id = (SELECT hold_id FROM booking_changes WHERE id = @id)
        RETURNING seat_label
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, toDepartureId),
        'labels': TypedValue(Type.textArray, taking),
        'booking': TypedValue(Type.uuid, bookingId),
        'id': TypedValue(Type.uuid, changeId),
      },
    );

    // The hold lapsed and the sweeper put the seats back before the money
    // arrived. Nothing moves, the order closes, and the capture stands as an
    // intent somebody has to refund — which is the honest outcome, and the
    // reason the window is deliberately longer than the payment's.
    if (claimed.length < taking.length) {
      await tx.execute(
        Sql.named(
          "UPDATE booking_changes SET state = 'expired' WHERE id = @id",
        ),
        parameters: {'id': TypedValue(Type.uuid, changeId)},
        ignoreRows: true,
      );
      return null;
    }

    await _relocate(
      tx,
      bookingId: bookingId,
      fromDepartureId: fromDepartureId,
      toDepartureId: toDepartureId,
      taking: taking,
      operatorId: row['operator_id']! as String,
      userId: row['created_by']! as String,
      changeId: changeId,
    );

    await tx.execute(
      Sql.named('''
        UPDATE holds SET state = 'consumed'
         WHERE id = (SELECT hold_id FROM booking_changes WHERE id = @id)
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );

    await tx.execute(
      Sql.named('''
        UPDATE booking_changes
           SET state = 'applied', applied_at = now()
         WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );

    // The difference, in the ledger, in the same transaction as the move. A
    // capture without the move is money nobody can explain; a move without
    // the capture is a journey nobody paid for.
    await _post(
      tx,
      posting,
      bookingId: bookingId,
      operatorId: row['operator_id']! as String,
      intentId: intentId,
    );

    return applied;
  });

  /// The escalated half of the paid path: take the seats, write the promise,
  /// and move nothing.
  Future<({ChangeOrder? order, ChangeRefusal? refusal})?> _reserve({
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

    if (row['purchaser'] != userId) return null;
    if (row['state'] != 'confirmed') {
      return (order: null, refusal: const ChangeAfterDeparture());
    }

    final fromDepartureId = row['departure_id']! as String;
    if (fromDepartureId == toDepartureId) {
      return (order: null, refusal: const ChangeToTheSameDeparture());
    }

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
    if (target.isEmpty) return (order: null, refusal: const ChangeOffRoute());
    final to = target.first.toColumnMap();

    if (to['operator_id'] != row['operator_id'] ||
        to['route_id'] != row['route_id'] ||
        to['status'] != 'scheduled') {
      return (order: null, refusal: const ChangeOffRoute());
    }

    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final paidFare = Money(row['fare_minor'] as int, currency);
    final seatsNeeded = (row['seat_count'] as int?) ?? 1;

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
      return (order: null, refusal: quoted.failureOrNull);
    }
    final quote = quoted.valueOrNull!;

    // An order that is already waiting. If nobody has answered a prompt for
    // it, the traveller has simply changed their mind and the old promise is
    // released; if a payment is in flight against it, releasing those seats
    // could strand money that is about to land, so this one refuses.
    final open = await tx.execute(
      Sql.named('''
        SELECT c.id::text AS id,
               EXISTS (SELECT 1 FROM payment_intents i
                        WHERE i.change_id = c.id
                          AND i.state IN ('created','pending','authorized',
                                          'indeterminate'))
                 AS in_flight
          FROM booking_changes c
         WHERE c.booking_id = @booking AND c.state = 'awaiting_payment'
           FOR UPDATE OF c
      '''),
      parameters: {'booking': TypedValue(Type.uuid, bookingId)},
    );
    if (open.isNotEmpty) {
      final existing = open.first.toColumnMap();
      if (existing['in_flight'] as bool? ?? false) {
        return (order: null, refusal: const ChangePaymentInFlight());
      }
      await _releaseOrder(tx, existing['id']! as String);
    }

    // Priced under the lock. A difference that evaporated between the list
    // and the tap is applied here and now: refusing somebody because the
    // price fell would be an insult with a 409 attached.
    if (quote.owed.minor == 0) {
      final moved = await _takeFreeSeats(
        tx,
        toDepartureId: toDepartureId,
        seatsNeeded: seatsNeeded,
        bookingId: bookingId,
      );
      final taken = moved.taking;
      if (taken == null) {
        return (
          order: null,
          refusal: ChangeDoesNotFit(seatsNeeded, moved.available),
        );
      }

      await _relocate(
        tx,
        bookingId: bookingId,
        fromDepartureId: fromDepartureId,
        toDepartureId: toDepartureId,
        taking: taken,
        operatorId: row['operator_id']! as String,
        userId: userId,
      );

      final free = ChangeApplied(
        bookingRef: ref,
        departureId: toDepartureId,
        departsAt: to['departs_at']! as DateTime,
        seatLabels: taken,
      );
      return (
        order: ChangeOrder(
          // No row is written for a change that owed nothing: there was
          // never a promise to keep, only a movement that happened.
          id: '',
          bookingId: bookingId,
          bookingRef: ref,
          toDepartureId: toDepartureId,
          departsAt: to['departs_at']! as DateTime,
          seatLabels: taken,
          fee: Money(0, currency),
          fareDifference: Money(0, currency),
          owed: Money(0, currency),
          expiresAt: now,
          state: 'applied',
          applied: free,
        ),
        refusal: null,
      );
    }

    // The seats, held rather than sold. An ordinary hold row, so the sweeper
    // that already puts lapsed holds back on sale puts these back too and
    // this table only has to notice afterwards.
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
      return (order: null, refusal: ChangeDoesNotFit(seatsNeeded, free.length));
    }

    final taking = [
      for (var i = 0; i < seatsNeeded; i++)
        free[i].toColumnMap()['seat_label'] as String,
    ];

    // Measured by the **database** clock, not this process's. The sweeper
    // that will release these seats compares against `now()`, and a window
    // computed from a machine that is a minute out is a window that is a
    // minute wrong in whichever direction hurts.
    final hold = await tx.execute(
      Sql.named('''
        INSERT INTO holds
          (operator_id, departure_id, user_id, seat_labels, expires_at,
           idempotency_key, channel)
        VALUES (@operator, @departure, @user, @labels,
                now() + make_interval(secs => @window), @key, 'app')
        RETURNING id::text AS id, expires_at
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, row['operator_id']! as String),
        'departure': TypedValue(Type.uuid, toDepartureId),
        'user': TypedValue(Type.uuid, userId),
        'labels': TypedValue(Type.textArray, taking),
        'window': TypedValue(Type.double, _paymentWindow.inSeconds.toDouble()),
        'key': TypedValue(
          Type.text,
          'change:$bookingId:$toDepartureId:${now.microsecondsSinceEpoch}',
        ),
      },
    );
    final held = hold.first.toColumnMap();
    final holdId = held['id']! as String;
    final expiresAt = held['expires_at']! as DateTime;

    for (final label in taking) {
      final claimed = await tx.execute(
        Sql.named('''
          UPDATE seats
             SET state = 'held', hold_id = @hold, held_until = @until,
                 booking_id = NULL
           WHERE departure_id = @departure AND seat_label = @label
             AND (state = 'available'
                  OR (state = 'held' AND held_until < now()))
          RETURNING seat_label
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, toDepartureId),
          'label': TypedValue(Type.text, label),
          'hold': TypedValue(Type.uuid, holdId),
          'until': TypedValue(Type.timestampTz, expiresAt),
        },
      );
      if (claimed.isEmpty) {
        return (
          order: null,
          refusal: ChangeDoesNotFit(seatsNeeded, taking.length - 1),
        );
      }
    }

    final order = await tx.execute(
      Sql.named('''
        INSERT INTO booking_changes
          (booking_id, operator_id, from_departure_id, to_departure_id,
           seat_labels, hold_id, fee_minor, difference_minor, owed_minor,
           currency, created_by, expires_at)
        VALUES (@booking, @operator, @from, @to, @labels, @hold, @fee,
                @difference, @owed, @currency, @user, @expires)
        RETURNING id::text AS id
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, row['operator_id']! as String),
        'from': TypedValue(Type.uuid, fromDepartureId),
        'to': TypedValue(Type.uuid, toDepartureId),
        'labels': TypedValue(Type.textArray, taking),
        'hold': TypedValue(Type.uuid, holdId),
        'fee': TypedValue(Type.bigInteger, quote.fee.minor),
        'difference': TypedValue(Type.bigInteger, quote.fareDifference.minor),
        'owed': TypedValue(Type.bigInteger, quote.owed.minor),
        'currency': TypedValue(Type.text, currency.code),
        'user': TypedValue(Type.uuid, userId),
        'expires': TypedValue(Type.timestampTz, expiresAt),
      },
    );

    return (
      order: ChangeOrder(
        id: order.first.toColumnMap()['id']! as String,
        bookingId: bookingId,
        bookingRef: ref,
        toDepartureId: toDepartureId,
        departsAt: to['departs_at']! as DateTime,
        seatLabels: taking,
        fee: quote.fee,
        fareDifference: quote.fareDifference,
        owed: quote.owed,
        expiresAt: expiresAt,
        state: 'awaiting_payment',
      ),
      refusal: null,
    );
  });

  /// Writes one balanced movement, grouped under a single `txn_id`.
  ///
  /// The deferred constraint trigger checks the sum at COMMIT — after this
  /// returns and beyond the reach of any handler here — so what happens in
  /// Dart is the courtesy and what happens at COMMIT is the guarantee.

  // ── The passenger who was late ────────────────────────────────────────────

  /// How far ahead a counter is offered coaches. Two days: a passenger who
  /// missed the 06:00 is put on today's or tomorrow's, and a list running a
  /// week out is a list an agent scrolls past.
  static const _missedHorizon = Duration(days: 2);

  /// The booking, its terms, and where it was supposed to leave from.
  ///
  /// Read under the tenant rather than as the traveller: this is a counter
  /// screen, and the reference is being read off a printed ticket by the
  /// person holding it. The policy join is the same `(id, version)` the sale
  /// stamped, so a passenger is judged by the terms they bought under.
  Future<Map<String, Object?>?> _missedBooking(
    TxSession tx,
    String ref,
    String operatorId,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.ref, b.state::text AS state, b.involuntary_change,
               b.fare_minor, b.currency, b.departure_id::text AS departure_id,
               b.operator_id::text AS operator_id,
               d.departs_at, d.status::text AS departure_status,
               r.origin_city, r.destination_city,
               os.name AS from_station,
               d.origin_station_id::text AS from_station_id,
               (SELECT count(*) FROM booking_seats s WHERE s.booking_id = b.id)
                 AS seat_count,
               p.missed_window_hours, p.missed_fee_bps
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          JOIN routes r ON r.id = d.route_id
          LEFT JOIN stations os ON os.id = d.origin_station_id
          LEFT JOIN refund_policies p
                 ON p.id = b.refund_policy_id
                AND p.version = b.refund_policy_version
         WHERE upper(b.ref) = upper(@ref)
           AND b.operator_id = @operator
      '''),
      parameters: {
        'ref': TypedValue(Type.text, ref.trim()),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  /// Zero and zero for a booking sold before the operator answered the
  /// question — which is "not offered", and is the honest default: honouring
  /// a missed ticket is a promise we must not make on a company's behalf.
  static MissedPolicy _missedPolicyFrom(Map<String, Object?> row) =>
      MissedPolicy(
        window: Duration(hours: row['missed_window_hours'] as int? ?? 0),
        feeBps: row['missed_fee_bps'] as int? ?? 0,
      );

  @override
  Future<MissedOptions?> missedOptions({
    required String bookingRef,
    required String operatorId,
    required DateTime now,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final row = await _missedBooking(tx, bookingRef, operatorId);
    if (row == null) return null;

    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final paidFare = Money(row['fare_minor'] as int, currency);
    final departedAt = row['departs_at']! as DateTime;
    final policy = _missedPolicyFrom(row);
    final seatsNeeded = (row['seat_count'] as int?) ?? 1;
    final involuntary = row['involuntary_change'] as bool? ?? false;
    final fromStationId = row['from_station_id'] as String?;

    MissedOptions shell({
      List<MissedOption> options = const [],
      ChangeRefusal? refusal,
    }) => MissedOptions(
      bookingRef: row['ref'] as String,
      originCity: row['origin_city'] as String,
      destinationCity: row['destination_city'] as String,
      seatsNeeded: seatsNeeded,
      departedAt: departedAt,
      paidFare: paidFare,
      policy: policy,
      options: options,
      fromStationName: row['from_station'] as String?,
      involuntary: involuntary,
      refusal: refusal,
    );

    // A ticket that was never paid for has nothing to carry forward, and a
    // refunded one has already been settled in money. Both are the same
    // sentence to an agent: this ticket is not a ticket.
    if (row['state'] != 'confirmed') {
      return shell(refusal: const ChangeAfterDeparture());
    }

    // The window, and whether any of this is offered at all, decided once
    // before a single row is priced.
    final gate = quoteMissed(
      paidFare: paidFare,
      newFare: paidFare,
      departedAt: departedAt,
      targetDepartsAt: now.add(const Duration(minutes: 1)),
      now: now,
      policy: policy,
      involuntary: involuntary,
    );
    if (gate.valueOrNull == null) return shell(refusal: gate.failureOrNull);

    // Every later coach this operator runs between the same two cities —
    // **not** on the same route id. A company's two Brazzaville terminals are
    // two routes in our table, and that is precisely the distinction a
    // passenger does not care about and this feature exists to cross.
    final candidates = await tx.execute(
      Sql.named('''
        SELECT d.id::text AS id, d.departs_at, d.arrives_at, d.fare_minor,
               s.name AS station_name, s.boarding_notes,
               d.origin_station_id::text AS station_id,
               (SELECT count(*) FROM seats st
                 WHERE st.departure_id = d.id
                   AND (st.state = 'available'
                        OR (st.state = 'held' AND st.held_until < now())))
                 AS free
          FROM departures d
          JOIN routes r ON r.id = d.route_id
          LEFT JOIN stations s ON s.id = d.origin_station_id
         WHERE d.operator_id = @operator
           AND r.origin_city = @from
           AND r.destination_city = @to
           AND d.id <> @current
           AND d.status = 'scheduled'
           AND d.departs_at > now()
           AND d.departs_at < now() + make_interval(secs => @horizon)
         ORDER BY d.departs_at
         LIMIT 20
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.text, row['origin_city']! as String),
        'to': TypedValue(Type.text, row['destination_city']! as String),
        'current': TypedValue(Type.uuid, row['departure_id']! as String),
        'horizon': TypedValue(Type.double, _missedHorizon.inSeconds.toDouble()),
      },
    );

    final options = <MissedOption>[];
    for (final candidate in candidates) {
      final c = candidate.toColumnMap();
      final free = (c['free'] as int?) ?? 0;
      final fare = Money(c['fare_minor'] as int, currency);

      final quoted = quoteMissed(
        paidFare: paidFare,
        newFare: fare,
        departedAt: departedAt,
        targetDepartsAt: c['departs_at']! as DateTime,
        now: now,
        policy: policy,
        involuntary: involuntary,
      );

      options.add(
        MissedOption(
          departureId: c['id']! as String,
          departsAt: c['departs_at']! as DateTime,
          arrivesAt: c['arrives_at']! as DateTime,
          fare: fare,
          seatsAvailable: free,
          stationName: c['station_name'] as String?,
          boardingNotes: c['boarding_notes'] as String?,
          // Computed here so the agent's screen and the passenger's ticket
          // cannot disagree about which "other gare" is meant. Two unnamed
          // yards count as the same one: we know nothing that says otherwise,
          // and warning about a difference we cannot see would be noise.
          sameStation:
              fromStationId == null ||
              c['station_id'] == null ||
              c['station_id'] == fromStationId,
          quote: quoted.valueOrNull,
          refusal:
              quoted.failureOrNull ??
              (free < seatsNeeded ? ChangeDoesNotFit(seatsNeeded, free) : null),
        ),
      );
    }

    return shell(options: options);
  });

  @override
  Future<({MissedTransfer? moved, ChangeRefusal? refusal})?> moveMissed({
    required String bookingRef,
    required String operatorId,
    required String toDepartureId,
    required String actorUserId,
    required DateTime now,
    String? stationId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final row = await _missedBooking(tx, bookingRef, operatorId);
    if (row == null) return null;
    if (row['state'] != 'confirmed') {
      return (moved: null, refusal: const ChangeAfterDeparture());
    }

    final bookingId = row['id'].toString();
    final fromDepartureId = row['departure_id']! as String;
    if (fromDepartureId == toDepartureId) {
      return (moved: null, refusal: const ChangeToTheSameDeparture());
    }

    // Both coaches locked in id order, exactly as a self-service change does:
    // two agents at two counters moving two passengers onto the same last
    // seat is the deadlock this ordering exists to prevent.
    final ids = [fromDepartureId, toDepartureId]..sort();
    await tx.execute(
      Sql.named(
        'SELECT id FROM departures WHERE id = ANY(@ids) ORDER BY id FOR UPDATE',
      ),
      parameters: {'ids': TypedValue(Type.uuidArray, ids)},
    );

    final target = await tx.execute(
      Sql.named('''
        SELECT d.departs_at, d.fare_minor, d.status::text AS status,
               d.operator_id::text AS operator_id,
               r.origin_city, r.destination_city,
               s.name AS station_name, s.boarding_notes
          FROM departures d
          JOIN routes r ON r.id = d.route_id
          LEFT JOIN stations s ON s.id = d.origin_station_id
         WHERE d.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, toDepartureId)},
    );
    if (target.isEmpty) return (moved: null, refusal: const ChangeOffRoute());
    final to = target.first.toColumnMap();

    // Another company, or another road. Both are a new purchase rather than a
    // transfer, and the tenant scope alone would not say so — an operator can
    // read its own departures on every route it runs.
    if (to['operator_id'] != operatorId ||
        to['origin_city'] != row['origin_city'] ||
        to['destination_city'] != row['destination_city']) {
      return (moved: null, refusal: const ChangeOffRoute());
    }
    if (to['status'] != 'scheduled') {
      return (moved: null, refusal: const ChangeIntoThePast());
    }

    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final paidFare = Money(row['fare_minor'] as int, currency);
    final involuntary = row['involuntary_change'] as bool? ?? false;

    // Re-quoted under the lock. The row was priced before an agent read it
    // out to somebody and took their money, which at a counter is a genuine
    // two minutes.
    final quoted = quoteMissed(
      paidFare: paidFare,
      newFare: Money(to['fare_minor'] as int, currency),
      departedAt: row['departs_at']! as DateTime,
      targetDepartsAt: to['departs_at']! as DateTime,
      now: now,
      policy: _missedPolicyFrom(row),
      involuntary: involuntary,
    );
    if (quoted case Err(:final failure)) {
      return (moved: null, refusal: failure);
    }
    final quote = quoted.valueOrNull!;

    // Cash in a drawer has to say which drawer, and a station named on a free
    // transfer is a drawer nobody counted. The database says the first half
    // too; this says which field to fix.
    if (quote.owed.minor > 0 && stationId == null) {
      return (moved: null, refusal: const MissedNeedsATill());
    }

    final seatsNeeded = (row['seat_count'] as int?) ?? 1;
    final moved = await _takeFreeSeats(
      tx,
      toDepartureId: toDepartureId,
      seatsNeeded: seatsNeeded,
      bookingId: bookingId,
    );
    final taking = moved.taking;
    if (taking == null) {
      return (
        moved: null,
        refusal: ChangeDoesNotFit(seatsNeeded, moved.available),
      );
    }

    await _relocate(
      tx,
      bookingId: bookingId,
      fromDepartureId: fromDepartureId,
      toDepartureId: toDepartureId,
      taking: taking,
      operatorId: operatorId,
      userId: actorUserId,
    );

    if (quote.owed.minor > 0) {
      final posting = Postings.missedTransfer(
        operatorId: operatorId,
        stationId: stationId!,
        paid: quote.owed,
      );
      // A posting that will not balance must never become half a movement.
      // It cannot happen — two entries of one amount — and the check is here
      // because "cannot happen" is what an unbalanced ledger is made of.
      if (posting case Err()) {
        throw StateError('missed transfer posting does not balance');
      }
      await _post(
        tx,
        posting.valueOrNull!,
        bookingId: bookingId,
        operatorId: operatorId,
      );
    }

    // The record of the conversation, written whether or not money moved.
    // This is the row somebody reads six weeks later when a passenger says
    // they paid twice.
    await tx.execute(
      Sql.named('''
        INSERT INTO missed_transfers
          (booking_id, operator_id, from_departure_id, to_departure_id,
           seat_labels, fee_minor, difference_minor, paid_minor, currency,
           station_id, moved_by)
        VALUES (@booking, @operator, @from, @to, @seats, @fee, @difference,
                @paid, @currency, @station, @actor)
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
        'from': TypedValue(Type.uuid, fromDepartureId),
        'to': TypedValue(Type.uuid, toDepartureId),
        'seats': TypedValue(Type.textArray, taking),
        'fee': TypedValue(Type.bigInteger, quote.fee.minor),
        'difference': TypedValue(Type.bigInteger, quote.fareDifference.minor),
        'paid': TypedValue(Type.bigInteger, quote.owed.minor),
        'currency': TypedValue(Type.text, currency.code),
        'station': TypedValue(
          Type.uuid,
          quote.owed.minor > 0 ? stationId : null,
        ),
        'actor': TypedValue(Type.uuid, actorUserId),
      },
      ignoreRows: true,
    );

    return (
      moved: MissedTransfer(
        bookingRef: row['ref'] as String,
        departureId: toDepartureId,
        departsAt: to['departs_at']! as DateTime,
        seatLabels: taking,
        paid: quote.owed,
        stationName: to['station_name'] as String?,
        boardingNotes: to['boarding_notes'] as String?,
      ),
      refusal: null,
    );
  });

  Future<void> _post(
    TxSession tx,
    LedgerTransaction posting, {
    required String bookingId,
    required String operatorId,
    String? intentId,
  }) async {
    final txnId = await tx.execute('SELECT gen_random_uuid() AS id');
    final txn = txnId.first.toColumnMap()['id'];

    for (final entry in posting.entries) {
      await tx.execute(
        Sql.named('''
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency,
             operator_id, booking_id, intent_id, memo)
          VALUES (@txn, @account, @direction::ledger_direction, @amount,
                  @currency, @operator, @booking, @intent, @memo)
        '''),
        parameters: {
          'txn': TypedValue(Type.uuid, txn.toString()),
          'account': TypedValue(Type.text, entry.account),
          'direction': TypedValue(Type.text, entry.direction.name),
          'amount': TypedValue(Type.bigInteger, entry.amount.minor),
          'currency': TypedValue(Type.text, entry.amount.currency.code),
          'operator': TypedValue(Type.uuid, entry.operatorId ?? operatorId),
          'booking': TypedValue(Type.uuid, bookingId),
          'intent': TypedValue(Type.uuid, intentId),
          'memo': TypedValue(Type.text, entry.memo),
        },
        ignoreRows: true,
      );
    }
  }

  /// Claims free seats and sells them to a booking in one step: the free
  /// path's half of the movement.
  Future<({List<String>? taking, int available})> _takeFreeSeats(
    TxSession tx, {
    required String toDepartureId,
    required int seatsNeeded,
    required String bookingId,
  }) async {
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
      return (taking: null, available: free.length);
    }

    final taking = [
      for (var i = 0; i < seatsNeeded; i++)
        free[i].toColumnMap()['seat_label'] as String,
    ];

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
        return (taking: null, available: taking.length - 1);
      }
    }

    return (taking: taking, available: free.length);
  }

  /// Cancels a waiting order and puts its seats back on sale.
  Future<void> _releaseOrder(TxSession tx, String changeId) async {
    await tx.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'available', hold_id = NULL, held_until = NULL
         WHERE state = 'held'
           AND hold_id = (SELECT hold_id FROM booking_changes WHERE id = @id)
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );
    await tx.execute(
      Sql.named('''
        UPDATE holds SET state = 'released'
         WHERE id = (SELECT hold_id FROM booking_changes WHERE id = @id)
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );
    await tx.execute(
      Sql.named(
        "UPDATE booking_changes SET state = 'cancelled' WHERE id = @id",
      ),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );
  }

  static ChangeOrder _orderFrom(Map<String, Object?> row) {
    final currency = Currency.byCode((row['currency'] as String).trim())!;
    return ChangeOrder(
      id: row['id']! as String,
      bookingId: row['booking_id']! as String,
      bookingRef: row['ref'] as String,
      toDepartureId: row['to_departure_id']! as String,
      departsAt: row['departs_at']! as DateTime,
      seatLabels: [
        for (final label in (row['seat_labels'] as List? ?? const [])) '$label',
      ],
      fee: Money(row['fee_minor'] as int, currency),
      fareDifference: Money(row['difference_minor'] as int, currency),
      owed: Money(row['owed_minor'] as int, currency),
      expiresAt: row['expires_at']! as DateTime,
      state: row['state']! as String,
    );
  }

  /// Moves a booking onto seats that have already been taken for it.
  ///
  /// Everything after the seats, and shared by the two ways of getting them:
  /// the free change, which claims them in the same breath, and the paid one,
  /// which claimed them a payment window earlier and is only now allowed to
  /// use them. The order inside is the same in both cases — the passengers
  /// are written onto the new seats before the old ones go back on sale.
  Future<void> _relocate(
    TxSession tx, {
    required String bookingId,
    required String fromDepartureId,
    required String toDepartureId,
    required List<String> taking,
    required String operatorId,
    required String userId,
    String? changeId,
  }) async {
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
          // What they paid for the journey, unchanged. A difference is
          // collected as its own payment against its own order; folding it
          // into the seat's fare would rewrite what the booking was sold for
          // and quietly move every refund quote with it.
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
    await _reissue(tx, bookingId, toDepartureId, operatorId);

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
        'operator': TypedValue(Type.uuid, operatorId),
        'after': TypedValue(Type.jsonb, {
          'toDepartureId': toDepartureId,
          'seats': taking,
          if (changeId != null) 'changeId': changeId,
        }),
      },
      ignoreRows: true,
    );
  }

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
