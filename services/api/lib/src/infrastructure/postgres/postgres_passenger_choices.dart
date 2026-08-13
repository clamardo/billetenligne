import 'dart:math';

import 'package:bel_api/src/application/ports/passenger_choices.dart';
import 'package:bel_api/src/application/ports/ticket_issuer.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

import 'seat_occupancy.dart';

/// The passenger's own choice, against Postgres (`08-disruption.md` §3.2).
///
/// Two scopes, and the split is the design:
///
///   * **Reading runs as the traveller.** Their booking is theirs by policy,
///     and the alternatives are the same departure and seat rows anybody
///     searching the route can already read. Nothing is widened to draw this
///     screen.
///   * **Committing escalates**, because moving a booking writes rows that
///     belong to the operator — seats, tickets, the booking's own state — and
///     no traveller connection may write any of them. The escalation is one
///     transaction wide, and everything it would otherwise trust is checked
///     inside it: the booking is still this user's, the exemption is still on
///     it, the disruption is still open, and the deadline has not passed.
///     The same shape as the protection movement, for the same reason.
final class PostgresPassengerChoices implements PassengerChoices {
  PostgresPassengerChoices(this._db, {TicketIssuer? issuer, Random? random})
    : _issuer = issuer,
      _random = random ?? Random.secure();

  final Database _db;
  final TicketIssuer? _issuer;
  final Random _random;

  /// Crockford's alphabet, as everywhere else a human reads a code aloud.
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  @override
  Future<TravelChoices?> optionsFor({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final booking = await _booking(tx, bookingRef);
    if (booking == null) return null;
    return _choicesFrom(tx, booking, now);
  });

  @override
  Future<({ChoiceApplied? applied, ChoiceRefusal? refusal})> choose({
    required String bookingRef,
    required String userId,
    required String optionId,
    required DateTime now,
  }) async {
    // Read as themselves first. A stranger's reference must reach the same
    // answer as a reference that does not exist, and it must reach it before
    // any privilege is taken.
    final seen = await _db.transaction(DbScope.traveller(userId), (tx) async {
      final booking = await _booking(tx, bookingRef);
      if (booking == null) return null;
      return (
        id: booking['id'].toString(),
        entitled: booking['involuntary_change'] as bool? ?? false,
        disrupted: booking['disruption_id'] != null,
        choices: await _choicesFrom(tx, booking, now),
      );
    });

    if (seen == null) return (applied: null, refusal: const NothingDisrupted());

    // The window before the option. "Vous ne pouvez plus changer" and "cette
    // option n'existe pas" are different sentences, and only one of them
    // tells the passenger what to do next.
    final gate = refuseChoice(
      involuntary: seen.entitled,
      disruptionOpen: seen.disrupted,
      deadline: seen.choices.deadline,
      now: now,
    );
    if (gate != null) return (applied: null, refusal: gate);

    if (optionId == 'refund') {
      return _refund(
        bookingId: seen.id,
        userId: userId,
        ref: bookingRef,
        now: now,
      );
    }

    // Keeping what they already have is a real answer and writes nothing.
    // Telling them it worked matters: the tap is how they stop worrying, and
    // it must not cost them their seat to press it.
    if (optionId == 'keep') {
      final assigned = seen.choices.fallback;
      return (
        applied: ChoiceApplied(
          bookingRef: bookingRef,
          kind: TravelChoiceKind.keep,
          departureId: assigned?.departureId,
          departsAt: assigned?.departsAt,
          seatLabels: assigned?.seatLabels ?? const [],
        ),
        refusal: null,
      );
    }

    // Anything else has to be a departure id. Checked here rather than at the
    // driver, which would throw rather than answer.
    if (!_looksLikeId(optionId)) {
      return (applied: null, refusal: const UnknownChoice());
    }

    // And the **lock** decides rather than the screen: the coach may have
    // filled between the two, and a passenger who taps a row that was there a
    // second ago deserves "it just went" rather than "no such option".
    return _move(
      bookingId: seen.id,
      userId: userId,
      ref: bookingRef,
      toDepartureId: optionId,
      seatsNeeded: seen.choices.seatsNeeded,
      now: now,
    );
  }

  /// The booking, its departure and whatever is happening to it. Read under
  /// the traveller's own scope, so "not yours" and "does not exist" are the
  /// same empty row.
  Future<Map<String, dynamic>?> _booking(TxSession tx, String ref) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.ref, b.state::text AS state, b.involuntary_change,
               b.departure_id::text AS departure_id,
               b.operator_id::text   AS operator_id,
               b.fare_minor, b.service_fee_minor, b.currency,
               d.departs_at, d.route_id::text AS route_id,
               r.origin_city, r.destination_city,
               (SELECT count(*)::int FROM booking_seats bs
                 WHERE bs.booking_id = b.id) AS seats,
               (SELECT string_agg(bs.seat_label, ',' ORDER BY bs.seat_label)
                  FROM booking_seats bs WHERE bs.booking_id = b.id) AS labels,
               o.trading_name, o.legal_name,
               x.id::text AS disruption_id, x.kind::text AS kind, x.note
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          JOIN routes r     ON r.id = d.route_id
          JOIN operators o  ON o.id = b.operator_id
          LEFT JOIN disruptions x
                 ON x.departure_id = b.departure_id AND x.resolved_at IS NULL
         WHERE b.ref = @ref AND b.state = 'confirmed'
      '''),
      parameters: {'ref': TypedValue(Type.text, ref)},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  /// The screen: what they have, what else is running, and the refund.
  Future<TravelChoices> _choicesFrom(
    TxSession tx,
    Map<String, dynamic> booking,
    DateTime now,
  ) async {
    final departureId = booking['departure_id']! as String;
    final departsAt = booking['departs_at']! as DateTime;
    final seatsNeeded = booking['seats'] as int? ?? 1;
    final currency =
        Currency.byCode(booking['currency'] as String) ?? Currency.xaf;
    final operatorName =
        (booking['trading_name'] ?? booking['legal_name']) as String?;

    final deadline = choiceDeadline(assignedDepartsAt: departsAt);
    final entitled = booking['involuntary_change'] as bool? ?? false;
    final disrupted = booking['disruption_id'] != null;

    final assigned = TravelChoice(
      kind: TravelChoiceKind.keep,
      id: 'keep',
      assigned: true,
      departureId: departureId,
      operatorName: operatorName,
      departsAt: departsAt,
      arrivesAt: booking['arrives_at'] as DateTime?,
      seatLabels: [
        for (final label in (booking['labels'] as String? ?? '').split(','))
          if (label.isNotEmpty) label,
      ],
    );

    // The platform floor: fare plus service fee, whatever the operator's
    // policy says, because the operator caused this (ADR-0015 rule 4).
    final quote = quoteRefund(
      faceValue: Money(booking['fare_minor'] as int, currency),
      serviceFee: Money(booking['service_fee_minor'] as int, currency),
      departsAt: departsAt,
      now: now,
      // The strictest terms anybody can write, passed on purpose: with
      // `operatorCaused` the function returns before it reads the policy at
      // all (ADR-0015 rule 4). An operator cannot configure their way out of
      // their own breakdown, and this line is where that is visible.
      policy: RefundPolicy.strict(),
      operatorCaused: true,
    );

    final refund = TravelChoice(
      kind: TravelChoiceKind.refund,
      id: 'refund',
      assigned: false,
      amount: quote.valueOrNull?.refundable ?? Money.zero(currency),
    );

    final open = entitled && disrupted && now.isBefore(deadline);

    // Alternatives are only worth a query while somebody can still take one.
    final alternatives = open
        ? await _alternatives(
            tx,
            operatorId: booking['operator_id']! as String,
            routeId: booking['route_id']! as String,
            departureId: departureId,
            departsAt: departsAt,
            seatsNeeded: seatsNeeded,
            now: now,
          )
        : const <TravelChoice>[];

    return TravelChoices(
      bookingRef: booking['ref']! as String,
      // Order is the design: what they already have first, so the safe state
      // is read before any decision; then what else is running; then the
      // refund, last and never hidden (§3.2).
      options: [assigned, ...alternatives, refund],
      deadline: deadline,
      seatsNeeded: seatsNeeded,
      originCity: booking['origin_city']! as String,
      destinationCity: booking['destination_city']! as String,
      disruptionKind: booking['kind'] as String? ?? '',
      reasonKey: booking['kind'] == null
          ? ''
          : 'disruption.kind.${booking['kind']}',
      note: booking['note'] as String?,
      open: open,
    );
  }

  /// The operator's own later departures on the same road.
  ///
  /// **Another company's coach is deliberately absent.** A passenger tapping
  /// one would be committing a competitor's seat without that competitor
  /// having agreed to carry them — which is the entire thing the protection
  /// agreement exists to obtain (§5). When that ask has been made and
  /// accepted, the passenger has already been moved and the coach they see
  /// here is the one they are on.
  Future<List<TravelChoice>> _alternatives(
    TxSession tx, {
    required String operatorId,
    required String routeId,
    required String departureId,
    required DateTime departsAt,
    required int seatsNeeded,
    required DateTime now,
  }) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT d.id::text AS id, d.departs_at, d.arrives_at,
               d.status::text AS status, d.route_id::text AS route_id,
               (SELECT count(*)::int FROM seats s
                 WHERE s.departure_id = d.id AND s.state = 'available')
                 AS seats_free
          FROM departures d
         WHERE d.route_id = @route
           AND d.operator_id = @operator
           AND d.id <> @current
           AND d.departs_at > @now
           -- Today and tomorrow. Somebody stranded this morning is asking
           -- what gets them there; a coach on Thursday is not an answer to
           -- that question, and a screen that offers it buries the two that
           -- are.
           AND d.departs_at < @now + INTERVAL '36 hours'
           AND d.status IN ('scheduled', 'delayed', 'boarding')
           AND (SELECT count(*) FROM seats s
                 WHERE s.departure_id = d.id AND s.state = 'available')
               >= @needed
         ORDER BY d.departs_at
         LIMIT 8
      '''),
      parameters: {
        'route': TypedValue(Type.uuid, routeId),
        'operator': TypedValue(Type.uuid, operatorId),
        'current': TypedValue(Type.uuid, departureId),
        'now': TypedValue(Type.timestampTz, now),
        'needed': TypedValue(Type.integer, seatsNeeded),
      },
    );

    final offers = <TravelChoice>[];
    for (final row in rows) {
      final r = row.toColumnMap();
      final free = r['seats_free'] as int? ?? 0;
      // Judged by the domain, not by the WHERE clause: an option the server
      // would refuse is worse than one that was never drawn.
      final offerable = offerableToPassenger(
        departureId: r['id']! as String,
        currentDepartureId: departureId,
        routeId: routeId,
        candidateRouteId: r['route_id']! as String,
        candidateStatus: r['status']! as String,
        departsAt: departsAt,
        candidateDepartsAt: r['departs_at']! as DateTime,
        now: now,
        seatsAvailable: free,
        seatsNeeded: seatsNeeded,
      );
      if (!offerable) continue;

      offers.add(
        TravelChoice(
          kind: TravelChoiceKind.move,
          id: r['id']! as String,
          assigned: false,
          departureId: r['id']! as String,
          departsAt: r['departs_at']! as DateTime,
          arrivesAt: r['arrives_at'] as DateTime?,
          seatsAvailable: free,
        ),
      );
    }
    return offers;
  }

  /// Moving one booking, at the passenger's own request.
  ///
  /// The dispatcher's wave with a party of one: seats taken before any is
  /// released, the ticket re-signed because the QR carries the seat
  /// (ADR-0007), and the message queued rather than sent inline (ADR-0019).
  Future<({ChoiceApplied? applied, ChoiceRefusal? refusal})> _move({
    required String bookingId,
    required String userId,
    required String ref,
    required String toDepartureId,
    required int seatsNeeded,
    required DateTime now,
  }) => _db.transaction(DbScope.platform(userId), (tx) async {
    final still = await _recheck(tx, bookingId, userId, now);
    if (still != null) return (applied: null, refusal: still);

    final from = await tx.execute(
      Sql.named(
        'SELECT departure_id::text AS id, operator_id::text AS operator_id '
        'FROM bookings WHERE id = @id',
      ),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    final fromDepartureId = from.first.toColumnMap()['id']! as String;
    final operatorId = from.first.toColumnMap()['operator_id']! as String;

    // Both departures locked in id order — the same rule the wave follows,
    // and here it matters more, because a hundred passengers each choosing
    // for themselves is a hundred concurrent movements between the same
    // pair of coaches.
    final ids = [fromDepartureId, toDepartureId]..sort();
    await tx.execute(
      Sql.named(
        'SELECT id FROM departures WHERE id = ANY(@ids) ORDER BY id FOR UPDATE',
      ),
      parameters: {'ids': TypedValue(Type.uuidArray, ids)},
    );

    // The target still has to belong to the same operator and the same road.
    // Re-read here rather than trusted from the screen: the option was drawn
    // before the lock.
    final target = await tx.execute(
      Sql.named('''
        SELECT d.status::text AS status, d.departs_at, d.route_id::text AS rid,
               d.operator_id::text AS operator_id
          FROM departures d WHERE d.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, toDepartureId)},
    );
    if (target.isEmpty) return (applied: null, refusal: const UnknownChoice());
    final to = target.first.toColumnMap();
    if (to['operator_id'] != operatorId) {
      return (applied: null, refusal: const UnknownChoice());
    }

    final free = await tx.execute(
      Sql.named('''
        SELECT seat_label FROM seats
         WHERE departure_id = @id AND state = 'available'
         ORDER BY seat_label
      '''),
      parameters: {'id': TypedValue(Type.uuid, toDepartureId)},
    );
    if (free.length < seatsNeeded) {
      return (
        applied: null,
        refusal: free.isEmpty
            ? const ChoiceNoLongerAvailable()
            : PartyDoesNotFit(seatsNeeded, free.length),
      );
    }

    final taking = [
      for (var i = 0; i < seatsNeeded; i++)
        free[i].toColumnMap()['seat_label'] as String,
    ];

    // **Taken before a single old one is released.** The transaction makes it
    // atomic either way; the ordering is what stops a paid passenger from
    // existing without a seat on any coach at all, including mid-raise.
    final missed = await SeatOccupancy.takeUnderBooking(
      tx,
      departureId: toDepartureId,
      operatorId: operatorId,
      labels: taking,
      bookingId: bookingId,
    );
    if (missed.isNotEmpty) {
      return (applied: null, refusal: const ChoiceNoLongerAvailable());
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
          // What they paid, carried across unchanged — onto a dearer coach as
          // readily as a cheaper one. An involuntary change never costs a
          // fare difference (ADR-0016), and it does not become one because
          // the passenger chose the coach themselves.
          'fare': TypedValue(Type.bigInteger, passenger['fare_minor']),
        },
        ignoreRows: true,
      );
    }

    await SeatOccupancy.releaseBooking(
      tx,
      bookingId,
      departureId: fromDepartureId,
    );

    await tx.execute(
      Sql.named('UPDATE bookings SET departure_id = @to WHERE id = @id'),
      parameters: {
        'id': TypedValue(Type.uuid, bookingId),
        'to': TypedValue(Type.uuid, toDepartureId),
      },
      ignoreRows: true,
    );

    await _reissue(tx, bookingId, toDepartureId, operatorId);

    // The same event the dispatcher's wave queues, because it is the same
    // fact from the passenger's side: you are on the 16:00 now, here is the
    // seat, here is the reference you already have.
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

    await _audit(
      tx,
      userId: userId,
      bookingId: bookingId,
      operatorId: operatorId,
      action: 'booking.self_rebooked',
      after: {'toDepartureId': toDepartureId, 'seats': taking},
    );

    return (
      applied: ChoiceApplied(
        bookingRef: ref,
        kind: TravelChoiceKind.move,
        departureId: toDepartureId,
        departsAt: to['departs_at'] as DateTime?,
        seatLabels: taking,
      ),
      refusal: null,
    );
  });

  /// Taking the money instead.
  ///
  /// The involuntary quote is the platform floor — fare plus service fee, no
  /// policy involved — and it is issued as a **claim collectable at any of
  /// the operator's counters**, because a disbursement back down a mobile
  /// money rail is a separately funded float that does not exist yet. Saying
  /// where the money is is the difference between a refund and a promise.
  Future<({ChoiceApplied? applied, ChoiceRefusal? refusal})> _refund({
    required String bookingId,
    required String userId,
    required String ref,
    required DateTime now,
  }) => _db.transaction(DbScope.platform(userId), (tx) async {
    final still = await _recheck(tx, bookingId, userId, now);
    if (still != null) return (applied: null, refusal: still);

    final rows = await tx.execute(
      Sql.named('''
        SELECT b.operator_id::text AS operator_id, b.fare_minor,
               b.service_fee_minor, b.currency, d.departs_at
          FROM bookings b JOIN departures d ON d.id = b.departure_id
         WHERE b.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    final row = rows.first.toColumnMap();
    final operatorId = row['operator_id']! as String;
    final currency = Currency.byCode(row['currency'] as String) ?? Currency.xaf;

    final quote = quoteRefund(
      faceValue: Money(row['fare_minor'] as int, currency),
      serviceFee: Money(row['service_fee_minor'] as int, currency),
      departsAt: row['departs_at']! as DateTime,
      now: now,
      // The strictest terms anybody can write, passed on purpose: with
      // `operatorCaused` the function returns before it reads the policy at
      // all (ADR-0015 rule 4). An operator cannot configure their way out of
      // their own breakdown, and this line is where that is visible.
      policy: RefundPolicy.strict(),
      operatorCaused: true,
    );
    if (quote.valueOrNull == null) {
      return (applied: null, refusal: const NothingDisrupted());
    }
    final refundable = quote.valueOrNull!.refundable;

    // Conditional, so two taps on a dropped connection are one refund.
    final moved = await tx.execute(
      Sql.named('''
        UPDATE bookings SET state = 'refunded'
         WHERE id = @id AND state = 'confirmed'
        RETURNING id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    if (moved.isEmpty)
      return (applied: null, refusal: const NothingDisrupted());

    await tx.execute(
      Sql.named('''
        UPDATE tickets SET voided_at = now()
         WHERE booking_id = @id AND voided_at IS NULL
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
      ignoreRows: true,
    );

    // Back on sale in the same transaction — and on a disrupted departure
    // that is the point of the whole screen: the seat this passenger gave up
    // is one the dispatcher can now offer to somebody still standing there.
    await SeatOccupancy.releaseBooking(tx, bookingId);

    final posting = Postings.refundApproved(
      operatorId: operatorId,
      bookingId: bookingId,
      // The whole fare comes out of the operator's payable and the fee out of
      // our own revenue. An operator-caused refund is not a fee we keep.
      fromOperator: Money(row['fare_minor'] as int, currency),
      fromServiceFee: Money(row['service_fee_minor'] as int, currency),
    );
    if (posting.valueOrNull == null) {
      return (applied: null, refusal: const NothingDisrupted());
    }

    final claimCode = _claimCode();
    final refund = await tx.execute(
      Sql.named('''
        INSERT INTO refunds
          (booking_id, operator_id, amount_minor, currency, rate_bps,
           destination, state, involuntary, claim_code, claim_expires_at,
           requested_by, approved_by, reason)
        VALUES (@booking, @operator, @amount, @currency, 10000,
                'agencyCash', 'claim_issued', TRUE, @claim,
                now() + interval '90 days', @actor, @actor,
                'passenger choice after disruption')
        RETURNING id
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
        'amount': TypedValue(Type.bigInteger, refundable.minor),
        'currency': TypedValue(Type.text, refundable.currency.code),
        'claim': TypedValue(Type.text, claimCode),
        'actor': TypedValue(Type.uuid, userId),
      },
    );

    await _postLedger(
      tx,
      posting.valueOrNull!,
      operatorId: operatorId,
      bookingId: bookingId,
      refundId: refund.first.toColumnMap()['id'].toString(),
    );

    // The code has to survive the app being closed, so it goes out by SMS as
    // well as onto the screen. Queued, never inline (ADR-0019): a passenger
    // at a roadside must not wait on a gateway to learn their money is safe.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('booking', @booking, 'booking.refunded',
                jsonb_build_object('bookingId', @booking::text),
                'booking.refunded:' || @booking::text)
        ON CONFLICT (dedupe_key) DO NOTHING
      '''),
      parameters: {'booking': TypedValue(Type.uuid, bookingId)},
      ignoreRows: true,
    );

    await _audit(
      tx,
      userId: userId,
      bookingId: bookingId,
      operatorId: operatorId,
      action: 'booking.self_refunded',
      after: {'amountMinor': refundable.minor, 'currency': currency.code},
    );

    return (
      applied: ChoiceApplied(
        bookingRef: ref,
        kind: TravelChoiceKind.refund,
        refunded: refundable,
        claimCode: claimCode,
      ),
      refusal: null,
    );
  });

  /// Everything the escalated transaction would otherwise have to trust.
  ///
  /// It runs with the privilege to write any operator's rows, so the four
  /// facts that make this passenger entitled are re-read inside it: the
  /// booking is theirs, it is still confirmed, the exemption is still on it,
  /// the disruption is still open — and the deadline has not passed while the
  /// screen was in somebody's pocket.
  Future<ChoiceRefusal?> _recheck(
    TxSession tx,
    String bookingId,
    String userId,
    DateTime now,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.involuntary_change, b.state::text AS state, d.departs_at,
               b.purchaser_user_id::text AS purchaser,
               (SELECT count(*)::int FROM disruptions x
                 WHERE x.departure_id = b.departure_id
                   AND x.resolved_at IS NULL) AS open_disruptions
          FROM bookings b JOIN departures d ON d.id = b.departure_id
         WHERE b.id = @id
           FOR UPDATE OF b
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    if (rows.isEmpty) return const NothingDisrupted();
    final row = rows.first.toColumnMap();

    if (row['purchaser'] != userId) return const NothingDisrupted();
    if (row['state'] != 'confirmed') return const NothingDisrupted();

    return refuseChoice(
      involuntary: row['involuntary_change'] as bool? ?? false,
      disruptionOpen: (row['open_disruptions'] as int? ?? 0) > 0,
      deadline: choiceDeadline(
        assignedDepartsAt: row['departs_at']! as DateTime,
      ),
      now: now,
    );
  }

  /// Re-signs this booking's tickets. The QR carries the seat and the
  /// departure (ADR-0007), so a moved passenger holding the old one scans as
  /// somebody else's seat at the door.
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

  /// The refund movement, exactly as the console posts it.
  ///
  /// **One `txn_id` for the whole movement.** A uuid per row would give every
  /// entry its own transaction, each of them unbalanced, and the deferred
  /// constraint trigger would refuse the lot at COMMIT — the right outcome,
  /// and still an outage instead of a refund.
  Future<void> _postLedger(
    TxSession tx,
    LedgerTransaction posting, {
    required String operatorId,
    required String bookingId,
    required String refundId,
  }) async {
    final generated = await tx.execute('SELECT gen_random_uuid() AS id');
    final txn = generated.first.toColumnMap()['id'].toString();

    for (final entry in posting.entries) {
      await tx.execute(
        Sql.named('''
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency,
             operator_id, booking_id, refund_id, memo)
          VALUES (@txn, @account, @direction::ledger_direction,
                  @amount, @currency, @operator, @booking, @refund, @memo)
        '''),
        parameters: {
          'txn': TypedValue(Type.uuid, txn),
          'account': TypedValue(Type.text, entry.account),
          'direction': TypedValue(Type.text, entry.direction.name),
          'amount': TypedValue(Type.bigInteger, entry.amount.minor),
          'currency': TypedValue(Type.text, entry.amount.currency.code),
          'operator': TypedValue(Type.uuid, entry.operatorId ?? operatorId),
          'booking': TypedValue(Type.uuid, bookingId),
          'refund': TypedValue(Type.uuid, refundId),
          'memo': TypedValue(Type.text, entry.memo),
        },
        ignoreRows: true,
      );
    }
  }

  /// The passenger is the actor, and the row says so. A movement nobody can
  /// attribute is one somebody will later be accused of.
  Future<void> _audit(
    TxSession tx, {
    required String userId,
    required String bookingId,
    required String operatorId,
    required String action,
    required Map<String, Object?> after,
  }) => tx.execute(
    Sql.named('''
      INSERT INTO audit_log
        (actor_id, actor_type, action, subject_type, subject_id, operator_id,
         after_state)
      VALUES (@actor, 'traveller', @action, 'booking', @booking, @operator,
              @after)
    '''),
    parameters: {
      'actor': TypedValue(Type.uuid, userId),
      'action': TypedValue(Type.text, action),
      'booking': TypedValue(Type.text, bookingId),
      'operator': TypedValue(Type.uuid, operatorId),
      'after': TypedValue(Type.jsonb, after),
    },
    ignoreRows: true,
  );

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool _looksLikeId(String value) => _uuid.hasMatch(value);

  String _claimCode() => String.fromCharCodes([
    for (var i = 0; i < 8; i++)
      _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
  ]);
}
