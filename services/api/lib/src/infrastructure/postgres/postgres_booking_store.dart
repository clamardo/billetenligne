import 'dart:math';

import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/booking_store.dart';
import '../../application/ports/ticket_issuer.dart';
import '../db/database.dart';

/// Bookings, tickets and the ledger — written together or not at all.
///
/// Each public method below is exactly one transaction, and the reason is
/// stated on the port: any prefix of "sell the seat, write the booking, post
/// the ledger, issue the ticket" committing alone is a specific disaster, and
/// the worst of them — a confirmed booking with no ledger row — is
/// indistinguishable from theft at the end of the month.
///
/// The scopes differ per method and that is load-bearing. Reserving runs as
/// the traveller (`bel_public`); capturing runs as the **operator**
/// (`bel_app`), because `bel_public` physically cannot write `sold` and there
/// must be no path from an anonymous internet request to a sold seat
/// (migration 0005).
final class PostgresBookingStore implements BookingStore {
  const PostgresBookingStore(this._db, {required TicketIssuer issuer})
    : _issuer = issuer;

  final Database _db;
  final TicketIssuer _issuer;

  // ── Reserve ───────────────────────────────────────────────────────────────

  @override
  Future<BookingRecord?> reserveFromHold({
    required String holdId,
    required String userId,
    required List<Passenger> passengers,
    required Money serviceFeePerSeat,
    required String paymentCode,
    required Duration payWithin,
    required String channel,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    // The hold must still be alive AND still theirs. `state = 'active'`
    // rather than a timestamp comparison in Dart: three API instances with
    // three slightly different clocks must not disagree about whose seat
    // this is, so every time comparison here is Postgres's.
    final held = await tx.execute(
      Sql.named('''
        UPDATE holds
           SET state = 'consumed'
         WHERE id = @hold
           AND user_id = app_user_id()
           AND state = 'active'
           AND expires_at > now()
        RETURNING operator_id, departure_id, seat_labels
      '''),
      parameters: {'hold': TypedValue(Type.uuid, holdId)},
    );

    // Lapsed, released, already spent, or somebody else's. One answer for all
    // four: the caller cannot act differently on any of them, and telling a
    // stranger which it was tells them whether the hold id they found is live.
    if (held.isEmpty) return null;

    final holdRow = held.first.toColumnMap();
    final operatorId = holdRow['operator_id'].toString();
    final departureId = holdRow['departure_id'].toString();
    final holdSeats = (holdRow['seat_labels'] as List).cast<String>().toSet();

    // The passenger list must describe the seats that were actually held.
    // Without this a client could hold 1A and book 1B, which is a free seat.
    for (final passenger in passengers) {
      if (!holdSeats.contains(passenger.seatLabel)) return null;
    }
    if (passengers.length != holdSeats.length) return null;

    // The price comes from the seat ROW, read inside this transaction. Not
    // from the request, which would be a client-supplied discount, and not
    // from an earlier read, which would be a window in which the fare could
    // change between the quote and the charge.
    final priced = await tx.execute(
      Sql.named('''
        SELECT seat_label, fare_minor, currency::text AS currency
          FROM seats
         WHERE departure_id = @departure AND seat_label = ANY(@labels)
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'labels': TypedValue(
          Type.textArray,
          passengers.map((p) => p.seatLabel).toList(),
        ),
      },
    );

    if (priced.length != passengers.length) return null;

    final fareBySeat = <String, Money>{
      for (final row in priced)
        row.toColumnMap()['seat_label'] as String: Money(
          row.toColumnMap()['fare_minor'] as int,
          Currency.byCode((row.toColumnMap()['currency'] as String).trim())!,
        ),
    };

    final seats = [
      for (final p in passengers)
        BookedSeat(
          seatLabel: p.seatLabel,
          passengerName: p.fullName,
          passengerPhone: p.phone,
          passengerIdNumber: p.idNumber,
          fare: fareBySeat[p.seatLabel]!,
        ),
    ];

    final currency = seats.first.fare.currency;
    final fare = seats.fold(Money(0, currency), (sum, s) => sum + s.fare);
    // Per seat, flat, never a percentage — a percentage feels like a tax and
    // is harder to trust. Four seats is four fees, which is what the departure
    // summary already quoted on the seat map.
    final serviceFee = Money(
      serviceFeePerSeat.minor * seats.length,
      currency,
    );
    final total = fare + serviceFee;

    final booking = await tx.execute(
      Sql.named('''
        INSERT INTO bookings
          (ref, operator_id, departure_id, hold_id, purchaser_user_id, state,
           fare_minor, service_fee_minor, total_minor, currency, channel,
           payment_code, payment_deadline,
           refund_policy_id, refund_policy_version)
        SELECT @ref, @operator, @departure, @hold, app_user_id(),
               'pending_payment', @fare, @fee, @total, @currency, @channel,
               @code, now() + make_interval(secs => @payWithin),
               -- Copied, not referenced. ADR-0015 rule 1: this booking is
               -- judged by the policy as it stands right now, forever, and
               -- an operator who writes better terms next month owes them to
               -- next month's travellers rather than to this one. A NULL
               -- here is an operator who has chosen no policy — they sell
               -- exactly as before, with no self-service refund.
               o.default_refund_policy_id, o.default_refund_policy_version
          FROM operators o
         WHERE o.id = @operator
        RETURNING id, ref, state::text AS state, payment_code, payment_deadline,
                  created_at
      '''),
      parameters: {
        'ref': TypedValue(Type.text, _generateRef()),
        'operator': TypedValue(Type.uuid, operatorId),
        'departure': TypedValue(Type.uuid, departureId),
        'hold': TypedValue(Type.uuid, holdId),
        'fare': TypedValue(Type.bigInteger, fare.minor),
        'fee': TypedValue(Type.bigInteger, serviceFee.minor),
        'total': TypedValue(Type.bigInteger, total.minor),
        'currency': TypedValue(Type.text, total.currency.code),
        'channel': TypedValue(Type.text, channel),
        'code': TypedValue(Type.text, paymentCode),
        'payWithin': TypedValue(Type.double, payWithin.inSeconds.toDouble()),
      },
    );

    final bookingRow = booking.first.toColumnMap();
    final bookingId = bookingRow['id'].toString();

    await _insertBookingSeats(tx, bookingId, seats);

    // The seats stay HELD, not sold, and the hold's expiry moves out to the
    // payment deadline. Selling them now would mean a ticket that can board
    // before anybody has paid; releasing them would mean a reservation whose
    // seat is gone by the time the traveller reaches the agency.
    await tx.execute(
      Sql.named('''
        UPDATE seats
           SET booking_id = @booking,
               held_until = now() + make_interval(secs => @payWithin)
         WHERE departure_id = @departure
           AND seat_label = ANY(@labels)
           AND state = 'held'
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'departure': TypedValue(Type.uuid, departureId),
        'labels': TypedValue(
          Type.textArray,
          seats.map((s) => s.seatLabel).toList(),
        ),
        'payWithin': TypedValue(Type.double, payWithin.inSeconds.toDouble()),
      },
      ignoreRows: true,
    );

    return BookingRecord(
      id: bookingId,
      ref: BookingRef.trusted(bookingRow['ref'] as String),
      operatorId: operatorId,
      departureId: departureId,
      state: bookingRow['state'] as String,
      seats: seats,
      fare: fare,
      serviceFee: serviceFee,
      total: total,
      trip: await _trip(tx, departureId),
      createdAt: bookingRow['created_at'] as DateTime,
      paymentCode: bookingRow['payment_code'] as String?,
      paymentDeadline: bookingRow['payment_deadline'] as DateTime?,
    );
  });

  // ── Capture ───────────────────────────────────────────────────────────────

  @override
  Future<BookingRecord?> captureCash({
    required String bookingId,
    required String operatorId,
    required String stationId,
    required String? soldByUserId,
    required LedgerTransaction posting,
  }) => _capture(
    bookingId: bookingId,
    operatorId: operatorId,
    posting: posting,
    paymentMethod: 'cash',
    stationId: stationId,
    soldByUserId: soldByUserId,
    intentId: null,
  );

  /// Confirm, sell the seats, post the ledger, issue the tickets, queue the
  /// message — one transaction, whatever paid for it.
  ///
  /// Cash and rail differ in what they record (a till and a vendor, or an
  /// intent) and in what they post (no commission, or commission netted at
  /// source). They do not differ in any of the four things that must happen
  /// together, which is why there is one of these and not two.
  Future<BookingRecord?> _capture({
    required String bookingId,
    required String operatorId,
    required LedgerTransaction posting,
    required String paymentMethod,
    required String? stationId,
    required String? soldByUserId,
    required String? intentId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Conditional on `pending_payment`, so two vendors collecting the same
    // reservation at two counters produce one sale. Checking in Dart first
    // would leave a window, and the window is a passenger charged twice.
    final confirmed = await tx.execute(
      Sql.named('''
        UPDATE bookings
           SET state = 'confirmed',
               confirmed_at = now(),
               paid_at = now(),
               payment_method = @method,
               station_id = @station,
               sold_by = @soldBy,
               -- Cleared on payment. It is a bearer: whoever holds it can pay
               -- for and collect this booking, and one that outlives its
               -- purpose is one somebody eventually finds.
               payment_code = NULL
         WHERE id = @booking
           AND operator_id = @operator
           AND state = 'pending_payment'
        RETURNING id, ref, departure_id, fare_minor, service_fee_minor,
                  total_minor, currency::text AS currency, state::text AS state
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
        'method': TypedValue(Type.text, paymentMethod),
        'station': TypedValue(Type.uuid, stationId),
        'soldBy': TypedValue(Type.uuid, soldByUserId),
      },
    );

    if (confirmed.isEmpty) return null;

    final row = confirmed.first.toColumnMap();
    final departureId = row['departure_id'].toString();
    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final ref = BookingRef.trusted(row['ref'] as String);

    // NOW the seats sell. Under the operator's scope, which is the only scope
    // that can write this state at all.
    await tx.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'sold', hold_id = NULL, held_until = NULL
         WHERE booking_id = @booking AND state = 'held'
      '''),
      parameters: {'booking': TypedValue(Type.uuid, bookingId)},
      ignoreRows: true,
    );

    await _postLedger(
      tx,
      posting,
      bookingId: bookingId,
      operatorId: operatorId,
      intentId: intentId,
    );

    final seats = await _readBookingSeats(tx, bookingId, currency);
    final trip = await _trip(tx, departureId);

    final signed = await _issuer.issue(
      bookingRef: ref,
      departureId: departureId,
      departsAt: trip.departsAt,
      routeCode: trip.routeCode,
      operatorCode: trip.operatorCode,
      seats: [
        for (final s in seats)
          (seatLabel: s.seatLabel, passengerName: s.passengerName),
      ],
    );

    final tickets = <IssuedTicket>[];
    for (final ticket in signed) {
      final inserted = await tx.execute(
        Sql.named('''
          INSERT INTO tickets
            (booking_id, operator_id, departure_id, seat_label,
             payload, signature, key_id, rotating_secret)
          VALUES (@booking, @operator, @departure, @seat,
                  @payload, @signature, @keyId, @secret)
          RETURNING id, issued_at
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
      );

      tickets.add(
        IssuedTicket(
          id: inserted.first.toColumnMap()['id'].toString(),
          seatLabel: ticket.seatLabel,
          payload: ticket.payload,
          keyId: ticket.keyId,
          rotatingSecret: ticket.rotatingSecret,
          issuedAt: inserted.first.toColumnMap()['issued_at'] as DateTime,
        ),
      );
    }

    // Composed here, drained by services/worker. A send is never inline with a
    // request, so a slow SMS gateway can never slow down a confirmation
    // (ADR-0019 rule 1) — and the dedupe key means a retried drain cannot
    // double-send, because nothing erodes trust like two conflicting messages
    // about one payment.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('booking', @booking, 'booking.confirmed', @payload, @dedupe)
        ON CONFLICT (dedupe_key) DO NOTHING
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'payload': TypedValue(Type.jsonb, {
          'bookingId': bookingId,
          'ref': ref.value,
          'departureId': departureId,
        }),
        'dedupe': TypedValue(Type.text, 'booking.confirmed:$bookingId'),
      },
      ignoreRows: true,
    );

    return BookingRecord(
      id: bookingId,
      ref: ref,
      operatorId: operatorId,
      departureId: departureId,
      state: row['state'] as String,
      seats: seats,
      fare: Money(row['fare_minor'] as int, currency),
      serviceFee: Money(row['service_fee_minor'] as int, currency),
      total: Money(row['total_minor'] as int, currency),
      trip: trip,
      createdAt: DateTime.now().toUtc(),
      tickets: tickets,
    );
  });

  @override
  Future<BookingRecord?> captureRail({
    required String bookingId,
    required String operatorId,
    required String railId,
    required String intentId,
    required LedgerTransaction posting,
  }) => _capture(
    bookingId: bookingId,
    operatorId: operatorId,
    posting: posting,
    paymentMethod: railId,
    stationId: null,
    soldByUserId: null,
    intentId: intentId,
  );

  // ── Reads ─────────────────────────────────────────────────────────────────

  @override
  Future<BookingRecord?> byPaymentCode({
    required String code,
    required String operatorId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT id, ref, departure_id, state::text AS state, fare_minor,
               service_fee_minor,
               total_minor, currency::text AS currency, payment_code, payment_deadline, created_at
          FROM bookings
         WHERE payment_code = @code
           AND operator_id = @operator
           AND state = 'pending_payment'
           AND payment_deadline > now()
      '''),
      parameters: {
        'code': TypedValue(Type.text, code),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    if (rows.isEmpty) return null;
    return _record(tx, rows.first.toColumnMap(), operatorId);
  });

  @override
  Future<BookingRecord?> byId({
    required String bookingId,
    required String operatorId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT id, ref, departure_id, state::text AS state, fare_minor,
               service_fee_minor,
               total_minor, currency::text AS currency, payment_code, payment_deadline, created_at
          FROM bookings WHERE id = @id AND operator_id = @operator
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    if (rows.isEmpty) return null;
    return _record(tx, rows.first.toColumnMap(), operatorId);
  });

  @override
  Future<List<BookingRecord>> forTraveller(String userId, {int limit = 50}) =>
      _db.transaction(DbScope.traveller(userId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT id, ref, operator_id, departure_id, state::text AS state,
                   fare_minor,
                   service_fee_minor, total_minor, currency::text AS currency, payment_code,
                   payment_deadline, created_at
              FROM bookings
             WHERE purchaser_user_id = app_user_id()
             ORDER BY created_at DESC
             LIMIT @limit
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );

        return [
          for (final row in rows)
            await _record(
              tx,
              row.toColumnMap(),
              row.toColumnMap()['operator_id'].toString(),
            ),
        ];
      });

  // ── Plumbing ──────────────────────────────────────────────────────────────

  Future<BookingRecord> _record(
    TxSession tx,
    Map<String, dynamic> row,
    String operatorId,
  ) async {
    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final bookingId = row['id'].toString();

    return BookingRecord(
      id: bookingId,
      ref: BookingRef.trusted(row['ref'] as String),
      operatorId: operatorId,
      departureId: row['departure_id'].toString(),
      state: row['state'] as String,
      seats: await _readBookingSeats(tx, bookingId, currency),
      fare: Money(row['fare_minor'] as int, currency),
      serviceFee: Money(row['service_fee_minor'] as int, currency),
      total: Money(row['total_minor'] as int, currency),
      trip: await _trip(tx, row['departure_id'].toString()),
      createdAt: row['created_at'] as DateTime,
      paymentCode: row['payment_code'] as String?,
      paymentDeadline: row['payment_deadline'] as DateTime?,
      tickets: await _readTickets(tx, bookingId),
    );
  }

  Future<void> _insertBookingSeats(
    TxSession tx,
    String bookingId,
    List<BookedSeat> seats,
  ) async {
    for (final seat in seats) {
      await tx.execute(
        Sql.named('''
          INSERT INTO booking_seats
            (booking_id, seat_label, passenger_name, passenger_phone,
             passenger_id_number, fare_minor)
          VALUES (@booking, @seat, @name, @phone, @idNumber, @fare)
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'seat': TypedValue(Type.text, seat.seatLabel),
          'name': TypedValue(Type.text, seat.passengerName),
          'phone': TypedValue(Type.text, seat.passengerPhone),
          'idNumber': TypedValue(Type.text, seat.passengerIdNumber),
          'fare': TypedValue(Type.bigInteger, seat.fare.minor),
        },
        ignoreRows: true,
      );
    }
  }

  Future<List<BookedSeat>> _readBookingSeats(
    TxSession tx,
    String bookingId,
    Currency currency,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT seat_label, passenger_name, passenger_phone,
               passenger_id_number, fare_minor
          FROM booking_seats WHERE booking_id = @booking
         ORDER BY seat_label
      '''),
      parameters: {'booking': TypedValue(Type.uuid, bookingId)},
    );

    return [
      for (final row in rows)
        BookedSeat(
          seatLabel: row.toColumnMap()['seat_label'] as String,
          passengerName: row.toColumnMap()['passenger_name'] as String,
          passengerPhone: row.toColumnMap()['passenger_phone'] as String?,
          passengerIdNumber:
              row.toColumnMap()['passenger_id_number'] as String?,
          fare: Money(row.toColumnMap()['fare_minor'] as int, currency),
        ),
    ];
  }

  Future<List<IssuedTicket>> _readTickets(
    TxSession tx,
    String bookingId,
  ) async {
    final rows = await tx.execute(
      // Voided tickets included, deliberately. A refunded ticket that simply
      // disappears from a traveller's list reads as our bug; one marked void
      // reads as what happened, and the conductor's manifest is where a void
      // has to *stop* somebody, not here.
      Sql.named('''
        SELECT id, seat_label, payload, key_id, rotating_secret,
               issued_at, voided_at
          FROM tickets WHERE booking_id = @booking
         ORDER BY seat_label
      '''),
      parameters: {'booking': TypedValue(Type.uuid, bookingId)},
    );

    return [
      for (final row in rows)
        IssuedTicket(
          id: row.toColumnMap()['id'].toString(),
          seatLabel: row.toColumnMap()['seat_label'] as String,
          payload: row.toColumnMap()['payload'] as String,
          keyId: row.toColumnMap()['key_id'] as int,
          rotatingSecret: row.toColumnMap()['rotating_secret'] as List<int>,
          issuedAt: row.toColumnMap()['issued_at'] as DateTime,
          voidedAt: row.toColumnMap()['voided_at'] as DateTime?,
        ),
    ];
  }

  Future<void> _postLedger(
    TxSession tx,
    LedgerTransaction posting, {
    required String bookingId,
    required String operatorId,
    String? intentId,
  }) async {
    // One txn_id groups the rows of one movement. The deferred constraint
    // trigger checks the sum at COMMIT — after this function returns, and
    // beyond the reach of any handler here, which is exactly why it is the
    // guarantee and the Dart check is only the courtesy.
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

  /// One join for the whole journey, because this is a read a traveller makes
  /// while standing in a queue and a second round trip on 2G is eight seconds.
  Future<TripSummary> _trip(TxSession tx, String departureId) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT d.departs_at, d.arrives_at,
               r.code AS route_code, r.origin_city, r.destination_city,
               o.code AS operator_code, o.legal_name AS operator_name
          FROM departures d
          JOIN routes r ON r.id = d.route_id
          JOIN operators o ON o.id = d.operator_id
         WHERE d.id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );

    final row = rows.first.toColumnMap();
    return TripSummary(
      operatorName: row['operator_name'] as String,
      operatorCode: row['operator_code'] as String,
      originCity: row['origin_city'] as String,
      destinationCity: row['destination_city'] as String,
      departsAt: row['departs_at'] as DateTime,
      arrivesAt: row['arrives_at'] as DateTime,
      routeCode: row['route_code'] as String,
    );
  }

  /// A reference is generated here rather than by the database, because
  /// `BookingRef` owns the alphabet and the length and a `DEFAULT` expression
  /// in SQL would be a second, silently diverging implementation of both.
  static String _generateRef() =>
      BookingRef.generate(_secure.nextInt).value;

  static final _secure = Random.secure();
}
