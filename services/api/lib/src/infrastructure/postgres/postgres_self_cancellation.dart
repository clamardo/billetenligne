import 'dart:convert';
import 'dart:math';

import 'package:bel_api/src/application/ports/self_cancellation.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart' hide Result;

/// The traveller cancelling their own booking, against Postgres (§8.2).
///
/// The same two-scope shape as the passenger's own choice, and for the same
/// reason:
///
///   * **Reading runs as the traveller.** Their booking is theirs by policy,
///     so a stranger's reference and a reference that does not exist reach
///     the same empty row without any code deciding that they should.
///   * **Cancelling escalates**, because it writes the operator's rows —
///     seats, tickets, the booking's state, the ledger. Everything the
///     escalated transaction would otherwise have to trust is re-read inside
///     it: the booking is still this user's, still in the state the screen
///     was drawn from, the coach has not left, and no payment has landed in
///     the meantime.
final class PostgresSelfCancellation implements SelfCancellation {
  PostgresSelfCancellation(this._db, {Random? random})
    : _random = random ?? Random.secure();

  final Database _db;
  final Random _random;

  /// Crockford's alphabet, as everywhere else a human reads a code aloud.
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  @override
  Future<CancellationOffer?> offer({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final row = await _booking(tx, bookingRef);
    return row == null ? null : _offerFrom(row, now);
  });

  @override
  Future<({CancellationDone? done, CancellationRefusal? refusal})?> cancel({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async {
    // As themselves first, and before any privilege is taken.
    final seen = await _db.transaction(DbScope.traveller(userId), (tx) async {
      final row = await _booking(tx, bookingRef);
      return row == null
          ? null
          : (id: row['id'].toString(), offer: _offerFrom(row, now));
    });

    // Not theirs, or not a reference at all. The same null the offer returns,
    // so the two verbs cannot be told apart by whoever is guessing.
    if (seen == null) return null;
    if (seen.offer.refusal != null) {
      return (done: null, refusal: seen.offer.refusal);
    }

    return _apply(
      bookingId: seen.id,
      userId: userId,
      ref: seen.offer.bookingRef,
      now: now,
    );
  }

  /// The booking, its departure, its terms and whether money is in flight —
  /// one read, under the traveller's own scope.
  Future<Map<String, Object?>?> _booking(TxSession tx, String ref) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.ref, b.state::text AS state, b.payment_method,
               b.fare_minor, b.service_fee_minor, b.currency,
               b.refund_policy_id, b.refund_policy_version,
               d.departs_at,
               r.origin_city, r.destination_city,
               (SELECT count(*) FROM booking_seats s WHERE s.booking_id = b.id)
                 AS seat_count,
               EXISTS (
                 SELECT 1 FROM payment_intents pi
                  WHERE pi.booking_id = b.id
                    AND pi.state IN ('created', 'pending', 'authorized',
                                     'indeterminate')
               ) AS payment_in_flight,
               p.name AS policy_name, p.tiers, p.destination,
               p.processing_hours, p.refund_service_fee,
               p.non_refundable_fares
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          -- The same city identifiers `BookingStore` sends, deliberately:
          -- this sheet renders beside a ticket card, and two spellings of one
          -- journey on one screen reads as two journeys.
          JOIN routes r ON r.id = d.route_id
          -- The version stamped on the booking, never the operator's current
          -- default. ADR-0015 rule 1 is this join.
          LEFT JOIN refund_policies p
                 ON p.id = b.refund_policy_id
                AND p.version = b.refund_policy_version
         WHERE upper(b.ref) = upper(@ref)
      '''),
      parameters: {'ref': TypedValue(Type.text, ref.trim())},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  CancellationOffer _offerFrom(Map<String, Object?> row, DateTime now) {
    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final fare = Money(row['fare_minor'] as int, currency);
    final serviceFee = Money(row['service_fee_minor'] as int, currency);
    final departsAt = row['departs_at']! as DateTime;
    final state = row['state'] as String;

    final policy = row['refund_policy_id'] == null ? null : _policyFrom(row);

    // A booking sold before the operator wrote any terms has none, and the
    // strictest possible reading is the honest one — the alternative is
    // applying today's policy to yesterday's customer, which ADR-0015 rule 1
    // exists to forbid. It only reaches the quote; the *destination* still
    // has to be something, and cash at a counter is the one every operator
    // here can honour.
    final destination = policy?.destination ?? RefundDestination.agencyCash;

    final standing = switch (state) {
      'pending_payment' => BookingStanding.awaitingPayment,
      'confirmed' => BookingStanding.paid,
      _ => BookingStanding.gone,
    };

    final decided = cancellationKind(
      standing: standing,
      paidInCash: row['payment_method'] == 'cash',
      destination: destination,
      departsAt: departsAt,
      now: now,
      paymentInFlight: row['payment_in_flight'] as bool? ?? false,
    );

    final base = CancellationOffer(
      bookingRef: row['ref'] as String,
      departsAt: departsAt,
      originCity: row['origin_city'] as String,
      destinationCity: row['destination_city'] as String,
      seatCount: (row['seat_count'] as int?) ?? 1,
      fare: fare,
      serviceFee: serviceFee,
      policy: policy,
      policyName: row['policy_name'] as String?,
    );

    if (decided.valueOrNull == null) {
      return CancellationOffer(
        bookingRef: base.bookingRef,
        departsAt: base.departsAt,
        originCity: base.originCity,
        destinationCity: base.destinationCity,
        seatCount: base.seatCount,
        fare: fare,
        serviceFee: serviceFee,
        policy: policy,
        policyName: base.policyName,
        refusal: decided.failureOrNull,
      );
    }

    final kind = decided.valueOrNull!;
    if (kind == CancellationKind.release) {
      // Nothing was paid. No quote, and the screen must not use the word
      // "remboursement" — there is nothing to give back.
      return CancellationOffer(
        bookingRef: base.bookingRef,
        departsAt: base.departsAt,
        originCity: base.originCity,
        destinationCity: base.destinationCity,
        seatCount: base.seatCount,
        fare: fare,
        serviceFee: serviceFee,
        policy: policy,
        policyName: base.policyName,
        kind: kind,
      );
    }

    final quoted = quoteRefund(
      faceValue: fare,
      serviceFee: serviceFee,
      departsAt: departsAt,
      now: now,
      policy: policy ?? RefundPolicy.strict(),
    );

    return CancellationOffer(
      bookingRef: base.bookingRef,
      departsAt: base.departsAt,
      originCity: base.originCity,
      destinationCity: base.destinationCity,
      seatCount: base.seatCount,
      fare: fare,
      serviceFee: serviceFee,
      policy: policy,
      policyName: base.policyName,
      kind: kind,
      quote: quoted.valueOrNull,
      givesNothingBack: cancellingCostsEverything(quoted),
    );
  }

  /// The escalated half. One transaction, and every fact re-read inside it.
  Future<({CancellationDone? done, CancellationRefusal? refusal})?> _apply({
    required String bookingId,
    required String userId,
    required String ref,
    required DateTime now,
  }) => _db.transaction(DbScope.platform(userId), (tx) async {
    // The departure is locked before anything is released, so a seat handed
    // back here and a seat sold on the same coach cannot interleave.
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.operator_id::text AS operator_id, b.ref,
               b.state::text AS state, b.payment_method,
               b.fare_minor, b.service_fee_minor, b.currency,
               b.purchaser_user_id::text AS purchaser,
               b.hold_id::text AS hold_id,
               b.refund_policy_id, b.refund_policy_version,
               d.departs_at,
               EXISTS (
                 SELECT 1 FROM payment_intents pi
                  WHERE pi.booking_id = b.id
                    AND pi.state IN ('created', 'pending', 'authorized',
                                     'indeterminate')
               ) AS payment_in_flight,
               p.tiers, p.destination, p.processing_hours,
               p.refund_service_fee, p.non_refundable_fares
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          LEFT JOIN refund_policies p
                 ON p.id = b.refund_policy_id
                AND p.version = b.refund_policy_version
         WHERE b.id = @id
         FOR UPDATE OF b
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    if (rows.isEmpty) return (done: null, refusal: const NothingToCancel());
    final row = rows.first.toColumnMap();

    // Still theirs. The read above ran with the privilege to see anybody's
    // booking, so the ownership that the traveller-scoped read established is
    // asserted again rather than assumed to have survived.
    if (row['purchaser'] != userId) return null;

    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final fare = Money(row['fare_minor'] as int, currency);
    final serviceFee = Money(row['service_fee_minor'] as int, currency);
    final policy = row['refund_policy_id'] == null ? null : _policyFrom(row);
    final state = row['state'] as String;

    final decided = cancellationKind(
      standing: switch (state) {
        'pending_payment' => BookingStanding.awaitingPayment,
        'confirmed' => BookingStanding.paid,
        _ => BookingStanding.gone,
      },
      paidInCash: row['payment_method'] == 'cash',
      destination: policy?.destination ?? RefundDestination.agencyCash,
      departsAt: row['departs_at']! as DateTime,
      now: now,
      paymentInFlight: row['payment_in_flight'] as bool? ?? false,
    );
    if (decided.valueOrNull == null) {
      return (done: null, refusal: decided.failureOrNull);
    }
    final kind = decided.valueOrNull!;
    final operatorId = row['operator_id']! as String;

    // Conditional on the state it was read in, so two taps on a dropped
    // connection are one cancellation.
    final moved = await tx.execute(
      Sql.named('''
        UPDATE bookings
           SET state = 'cancelled', cancelled_at = now()
         WHERE id = @id AND state = @was::booking_state
        RETURNING id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, bookingId),
        'was': TypedValue(Type.text, state),
      },
    );
    if (moved.isEmpty) return (done: null, refusal: const NothingToCancel());

    await tx.execute(
      Sql.named('''
        UPDATE tickets SET voided_at = now()
         WHERE booking_id = @id AND voided_at IS NULL
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
      ignoreRows: true,
    );

    // Back on sale in the same transaction. This is the part that makes
    // self-service worth building at all: a seat freed at 22:00 the night
    // before is a seat somebody else buys, and a cancellation that waits for
    // an agency to open is a seat that travels empty.
    await tx.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'available', booking_id = NULL, hold_id = NULL,
               held_until = NULL
         WHERE booking_id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
      ignoreRows: true,
    );

    if (row['hold_id'] != null) {
      await tx.execute(
        Sql.named('''
          UPDATE holds SET state = 'released'
           WHERE id = @hold AND state = 'active'
        '''),
        parameters: {'hold': TypedValue(Type.uuid, row['hold_id'] as String)},
        ignoreRows: true,
      );
    }

    if (kind == CancellationKind.release) {
      await _audit(
        tx,
        userId: userId,
        bookingId: bookingId,
        operatorId: operatorId,
        action: 'booking.self_cancelled',
        after: {'kind': 'release'},
      );
      return (
        done: CancellationDone(bookingRef: row['ref'] as String, kind: kind),
        refusal: null,
      );
    }

    final quoted = quoteRefund(
      faceValue: fare,
      serviceFee: serviceFee,
      departsAt: row['departs_at']! as DateTime,
      now: now,
      policy: policy ?? RefundPolicy.strict(),
    );
    final refundable = quoted.valueOrNull?.refundable ?? Money(0, currency);

    // A cancellation the terms give nothing back for is still a cancellation.
    // The seat is freed, the ticket is void, and no refund row is written —
    // because a refund of nought is a row somebody would later try to pay.
    if (refundable.minor == 0) {
      await _audit(
        tx,
        userId: userId,
        bookingId: bookingId,
        operatorId: operatorId,
        action: 'booking.self_cancelled',
        after: {'kind': kind.name, 'refundMinor': 0},
      );
      return (
        done: CancellationDone(
          bookingRef: row['ref'] as String,
          kind: kind,
          refunded: refundable,
        ),
        refusal: null,
      );
    }

    // Whose pocket it comes out of. The service fee is ours, and it only
    // moves when the operator's policy says it does.
    final fromServiceFee = (policy?.refundServiceFee ?? false)
        ? serviceFee
        : Money(0, currency);
    final fromOperator = refundable - fromServiceFee;
    if (fromOperator.minor < 0) {
      return (done: null, refusal: const NothingToCancel());
    }

    final posting = Postings.refundApproved(
      operatorId: operatorId,
      bookingId: bookingId,
      fromOperator: fromOperator,
      fromServiceFee: fromServiceFee,
    );
    if (posting.valueOrNull == null) {
      return (done: null, refusal: const NothingToCancel());
    }

    final atCounter = kind == CancellationKind.claimAtCounter;
    final claimCode = atCounter ? _claimCode() : null;

    final refund = await tx.execute(
      Sql.named('''
        INSERT INTO refunds
          (booking_id, operator_id, amount_minor, currency, rate_bps,
           destination, state, involuntary, claim_code, claim_expires_at,
           requested_by, approved_by, reason)
        VALUES (@booking, @operator, @amount, @currency, @rate, @destination,
                @state::refund_state, FALSE, @claim,
                CASE WHEN @claim::text IS NULL THEN NULL
                     ELSE now() + interval '90 days' END,
                @actor, @actor, 'cancelled by the traveller')
        RETURNING id, claim_code, claim_expires_at
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
        'amount': TypedValue(Type.bigInteger, refundable.minor),
        'currency': TypedValue(Type.text, currency.code),
        'rate': TypedValue(Type.integer, quoted.valueOrNull!.rateBps),
        'destination': TypedValue(
          Type.text,
          atCounter ? 'agencyCash' : 'source',
        ),
        // `approved` and not `paid`: a disbursement back down a mobile-money
        // rail is a separately funded float and a different API, and it is
        // not built. The row says what is owed; nothing here claims it moved.
        'state': TypedValue(Type.text, atCounter ? 'claim_issued' : 'approved'),
        'claim': TypedValue(Type.text, claimCode),
        'actor': TypedValue(Type.uuid, userId),
      },
    );
    final refundRow = refund.first.toColumnMap();

    await _postLedger(
      tx,
      posting.valueOrNull!,
      operatorId: operatorId,
      bookingId: bookingId,
      refundId: refundRow['id'].toString(),
    );

    // Queued, never inline (ADR-0019). The claim code has to survive the app
    // being closed, so it goes out by SMS as well as onto the screen.
    await tx.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('booking', @booking, 'booking.cancelled',
                jsonb_build_object('bookingId', @booking::text),
                'booking.cancelled:' || @booking::text)
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
      action: 'booking.self_cancelled',
      after: {
        'kind': kind.name,
        'refundMinor': refundable.minor,
        'currency': currency.code,
      },
    );

    return (
      done: CancellationDone(
        bookingRef: row['ref'] as String,
        kind: kind,
        refunded: refundable,
        claimCode: refundRow['claim_code'] as String?,
        claimExpiresAt: refundRow['claim_expires_at'] as DateTime?,
        processingWindow: atCounter
            ? null
            : (policy?.processingWindow ?? const Duration(hours: 72)),
      ),
      refusal: null,
    );
  });

  static RefundPolicy _policyFrom(Map<String, Object?> row) {
    final raw = row['tiers'];
    final tiers = (raw is String ? jsonDecode(raw) : raw) as List<Object?>;

    return RefundPolicy(
      id: row['refund_policy_id'].toString(),
      version: row['refund_policy_version'] as int? ?? 1,
      destination: RefundDestination.values.firstWhere(
        (d) => d.name == row['destination'],
        orElse: () => RefundDestination.source,
      ),
      processingWindow: Duration(hours: row['processing_hours'] as int? ?? 72),
      refundServiceFee: row['refund_service_fee'] as bool? ?? false,
      nonRefundableFareCodes: {
        ...?(row['non_refundable_fares'] as List?)?.map((f) => '$f'),
      },
      tiers: [
        for (final entry in tiers.cast<Map<String, Object?>>())
          RefundTier(
            minLeadTime: Duration(
              minutes: entry['minLeadTimeMinutes'] as int? ?? 0,
            ),
            rateBps: entry['rateBps'] as int? ?? 0,
            flatFeeMinor: entry['flatFeeMinor'] as int? ?? 0,
          ),
      ],
    );
  }

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

  /// The traveller is the actor, and the row says so. "Who cancelled this?"
  /// is the first question at a counter when somebody turns up anyway.
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

  String _claimCode() => String.fromCharCodes([
    for (var i = 0; i < 8; i++)
      _alphabet.codeUnitAt(_random.nextInt(_alphabet.length)),
  ]);
}
