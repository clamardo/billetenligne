import 'dart:convert';

import 'package:bel_api/src/application/ports/disbursement_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import 'sweepers.dart';

/// Sends the refunds that are owed to a wallet, and finds out whether they
/// arrived.
///
/// A `source` refund has been a two-thirds-finished thing since the refund
/// desk shipped: the policy decided it, the ledger raised the debt, and then
/// the row sat at `approved` while every screen told the traveller to walk
/// into an agency. This is the last third.
///
/// **Two steps, deliberately not one.**
///
///   * `_send` turns an approved refund into a disbursement intent and asks
///     the rail to pay it. It never posts to the ledger, because a request is
///     not a movement — a rail can accept a transfer and fail it a minute
///     later, and a ledger that recorded the asking would show a float
///     draining on money that never left.
///   * `_settle` asks the rail what happened and posts when the answer is
///     yes. That is the only place `psp:<rail>:disbursement` is ever credited.
///
/// **A terminal failure becomes a claim at a counter, not a dead row.** The
/// traveller is owed the money either way; the only question is how they get
/// it. A refund left `failed` is a debt on our books, a person out of pocket,
/// and nobody told — so a barred wallet or an empty float turns into a code
/// and an SMS, which is exactly where this product was before the rail
/// existed. Falling back is worth more than the tidiness of a `failed` row.
final class DisbursementPass {
  const DisbursementPass({
    required Database db,
    required Map<String, DisbursementGateway> rails,
    Clock clock = const SystemClock(),
  }) : _db = db,
       _rails = rails,
       _clock = clock;

  final Database _db;

  /// Rail id → the payout side of that rail. **Missing is a normal state.** A
  /// card has no payout API this system can reach and Orange Money's Web
  /// Payment product has none at all, so those refunds go to a counter rather
  /// than waiting for a rail that is never going to appear.
  final Map<String, DisbursementGateway> _rails;

  final Clock _clock;

  Future<SweepResult> run({int limit = 50}) async {
    final sent = await _send(limit: limit);
    final settled = await _settle(limit: limit);
    return SweepResult(name: 'refunds.disbursed', affected: sent + settled);
  }

  // ── Sending ───────────────────────────────────────────────────────────────

  Future<int> _send({required int limit}) async {
    final queued = await _db.transaction(const DbScope.worker(), (tx) async {
      // Claimed in one statement, and `FOR UPDATE SKIP LOCKED` is the reason
      // two workers can run at once: the second sees an empty queue rather
      // than the same refund, and money is sent once.
      final rows = await tx.execute(
        Sql.named('''
          WITH claimed AS (
            SELECT f.id
              FROM refunds f
             WHERE f.state = 'approved'
               AND f.destination = 'source'
               AND f.disburse_to IS NOT NULL
             ORDER BY f.created_at
             LIMIT @limit
             FOR UPDATE SKIP LOCKED
          )
          UPDATE refunds f
             SET state = 'processing'
            FROM claimed c
           WHERE f.id = c.id
          RETURNING f.id, f.booking_id, f.operator_id, f.amount_minor,
                    f.currency, f.disburse_to,
                    (SELECT ref FROM bookings b WHERE b.id = f.booking_id)
                      AS booking_ref,
                    (SELECT pi.rail_id FROM payment_intents pi
                      WHERE pi.booking_id = f.booking_id
                        AND pi.direction = 'collect'
                        AND pi.state = 'captured'
                      ORDER BY pi.terminal_at DESC NULLS LAST
                      LIMIT 1) AS rail_id
        '''),
        parameters: {'limit': TypedValue(Type.integer, limit)},
      );
      return [for (final row in rows) row.toColumnMap()];
    });

    var count = 0;
    for (final refund in queued) {
      final railId = refund['rail_id'] as String?;
      final gateway = railId == null ? null : _rails[railId];

      if (gateway == null) {
        // Nothing is going to send this. Say so now rather than leaving it in
        // `processing` for a pass that will never handle it.
        await _fallBackToCounter(
          refundId: refund['id'].toString(),
          reason: 'no disbursement rail for ${railId ?? 'an unknown rail'}',
        );
        count++;
        continue;
      }

      final amount = Money(
        refund['amount_minor'] as int,
        Currency.byCode((refund['currency'] as String).trim())!,
      );
      final refundId = refund['id'].toString();

      final intentId = await _openIntent(
        refundId: refundId,
        bookingId: refund['booking_id'].toString(),
        operatorId: refund['operator_id'].toString(),
        railId: railId!,
        msisdn: refund['disburse_to'] as String,
        amount: amount,
      );

      final outcome = await gateway.disburse(
        DisbursementRequest(
          // The refund id, and it is the rail's idempotency key: this pass is
          // retryable, and a retry that sent a second transfer would pay the
          // traveller twice out of a float somebody has to fund.
          reference: refundId,
          amount: amount,
          payeeMsisdn: refund['disburse_to'] as String,
          description: 'BEL-${refund['booking_ref']}',
        ),
      );

      await _recordEvent(intentId, 'poll', outcome.raw);

      if (outcome.state == PaymentState.failed) {
        await _fallBackToCounter(
          refundId: refundId,
          intentId: intentId,
          failureCode: outcome.failureCode,
          reason: 'the rail refused the transfer',
        );
      } else {
        await _markIntent(
          intentId,
          state: PaymentState.pending,
          railTransactionId: outcome.railTransactionId,
        );
      }
      count++;
    }

    return count;
  }

  // ── Settling ──────────────────────────────────────────────────────────────

  Future<int> _settle({required int limit}) async {
    final inFlight = await _db.transaction(const DbScope.worker(), (tx) async {
      final rows = await tx.execute(
        Sql.named('''
          SELECT pi.id, pi.rail_id, pi.psp_reference, pi.created_at,
                 f.id AS refund_id, f.booking_id, f.operator_id,
                 f.amount_minor, f.currency
            FROM payment_intents pi
            JOIN refunds f ON f.disbursement_intent_id = pi.id
           WHERE pi.direction = 'disburse'
             AND pi.state IN ('pending', 'authorized')
           ORDER BY pi.last_polled_at NULLS FIRST
           LIMIT @limit
        '''),
        parameters: {'limit': TypedValue(Type.integer, limit)},
      );
      return [for (final row in rows) row.toColumnMap()];
    });

    var count = 0;
    for (final row in inFlight) {
      final gateway = _rails[row['rail_id'] as String];
      if (gateway == null) continue;

      final intentId = row['id'].toString();
      final refundId = row['refund_id'].toString();

      final outcome = await gateway.queryDisbursement(
        reference: refundId,
        railTransactionId: row['psp_reference'] as String?,
      );

      await _recordEvent(intentId, 'poll', outcome.raw);
      await _markPolled(intentId);

      switch (outcome.state) {
        case PaymentState.captured:
          await _complete(
            refundId: refundId,
            intentId: intentId,
            bookingId: row['booking_id'].toString(),
            operatorId: row['operator_id'].toString(),
            railId: row['rail_id'] as String,
            amount: Money(
              row['amount_minor'] as int,
              Currency.byCode((row['currency'] as String).trim())!,
            ),
            railTransactionId: outcome.railTransactionId,
          );
          count++;

        case PaymentState.failed:
          await _fallBackToCounter(
            refundId: refundId,
            intentId: intentId,
            failureCode: outcome.failureCode,
            reason: 'the transfer failed',
          );
          count++;

        default:
          // Still moving, or a status nobody here recognises. Neither is an
          // answer, and an unrecognised one is emphatically not a refusal:
          // closing a refund on a code a telco added last month would leave
          // somebody out of pocket with a row saying they were paid.
          //
          // Silence for long enough is its own answer, and the counter is
          // where it goes — the same rule the collection poller applies, and
          // for the same reason.
          if (_clock
              .now()
              .difference(row['created_at'] as DateTime)
              .inHours >=
              24) {
            await _fallBackToCounter(
              refundId: refundId,
              intentId: intentId,
              reason: 'no answer from the rail within 24 hours',
            );
            count++;
          }
      }
    }

    return count;
  }

  // ── Rows ──────────────────────────────────────────────────────────────────

  Future<String> _openIntent({
    required String refundId,
    required String bookingId,
    required String operatorId,
    required String railId,
    required String msisdn,
    required Money amount,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    // `ON CONFLICT` on the idempotency key rather than a check: a pass that
    // died between opening the intent and sending it must find its own row
    // again, not create a second one for the same refund.
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO payment_intents
          (booking_id, operator_id, rail_id, msisdn, amount_minor, currency,
           idempotency_key, direction, state)
        VALUES (@booking, @operator, @rail, @msisdn, @amount, @currency,
                @key, 'disburse', 'created')
        ON CONFLICT (idempotency_key) DO UPDATE SET rail_id = EXCLUDED.rail_id
        RETURNING id
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
        'rail': TypedValue(Type.text, railId),
        'msisdn': TypedValue(Type.text, msisdn),
        'amount': TypedValue(Type.bigInteger, amount.minor),
        'currency': TypedValue(Type.text, amount.currency.code),
        'key': TypedValue(Type.text, 'refund:$refundId'),
      },
    );
    final intentId = rows.first.toColumnMap()['id'].toString();

    await tx.execute(
      Sql.named('''
        UPDATE refunds SET disbursement_intent_id = @intent WHERE id = @id
      '''),
      parameters: {
        'intent': TypedValue(Type.uuid, intentId),
        'id': TypedValue(Type.uuid, refundId),
      },
      ignoreRows: true,
    );
    return intentId;
  });

  Future<void> _markIntent(
    String intentId, {
    required PaymentState state,
    String? railTransactionId,
    PaymentFailureCode? failureCode,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    await tx.execute(
      Sql.named('''
        UPDATE payment_intents
           SET state = @state::payment_state,
               failure_code = COALESCE(@failure, failure_code),
               psp_reference = COALESCE(@ref, psp_reference),
               terminal_at = CASE
                 WHEN @state IN ('captured','failed','expired','cancelled')
                   THEN now() ELSE terminal_at END
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, intentId),
        'state': TypedValue(Type.text, state.name),
        'failure': TypedValue(Type.text, failureCode?.name),
        'ref': TypedValue(Type.text, railTransactionId),
      },
      ignoreRows: true,
    );
  });

  Future<void> _markPolled(String intentId) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        await tx.execute(
          Sql.named('''
            UPDATE payment_intents
               SET last_polled_at = now(), poll_attempts = poll_attempts + 1
             WHERE id = @id
          '''),
          parameters: {'id': TypedValue(Type.uuid, intentId)},
          ignoreRows: true,
        );
      });

  Future<void> _recordEvent(
    String intentId,
    String source,
    Map<String, Object?> raw,
  ) => _db.transaction(const DbScope.worker(), (tx) async {
    await tx.execute(
      Sql.named('''
        INSERT INTO payment_events (intent_id, source, raw)
        VALUES (@intent, @source, @raw::jsonb)
      '''),
      parameters: {
        'intent': TypedValue(Type.uuid, intentId),
        'source': TypedValue(Type.text, source),
        'raw': TypedValue(Type.text, _json(raw)),
      },
      ignoreRows: true,
    );
  });

  /// The money left. Ledger, state and the message, in one transaction —
  /// a refund marked paid that failed to post is a hole in the books, and a
  /// posting with no row is a traveller nobody told.
  Future<void> _complete({
    required String refundId,
    required String intentId,
    required String bookingId,
    required String operatorId,
    required String railId,
    required Money amount,
    String? railTransactionId,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    final closed = await tx.execute(
      Sql.named('''
        UPDATE refunds
           SET state = 'completed', completed_at = now()
         WHERE id = @id AND state = 'processing'
        RETURNING id
      '''),
      parameters: {'id': TypedValue(Type.uuid, refundId)},
    );
    // Somebody else settled it. Posting again would credit the float twice.
    if (closed.isEmpty) return;

    await tx.execute(
      Sql.named('''
        UPDATE payment_intents
           SET state = 'captured', terminal_at = now(),
               psp_reference = COALESCE(@ref, psp_reference)
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, intentId),
        'ref': TypedValue(Type.text, railTransactionId),
      },
      ignoreRows: true,
    );

    final posting = Postings.refundDisbursed(
      operatorId: operatorId,
      bookingId: bookingId,
      rail: railId,
      amount: amount,
    );
    final entries = posting.valueOrNull;
    if (entries == null) return;

    final generated = await tx.execute('SELECT gen_random_uuid() AS id');
    final txn = generated.first.toColumnMap()['id'].toString();
    for (final entry in entries.entries) {
      await tx.execute(
        Sql.named('''
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency,
             operator_id, booking_id, refund_id, memo)
          VALUES (@txn, @account, @direction::ledger_direction, @amount,
                  @currency, @operator, @booking, @refund, @memo)
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

    await _queueMessage(tx, bookingId: bookingId, event: 'refund.sent');
  });

  /// The rail said no, or said nothing for long enough. The traveller is still
  /// owed the money, so it becomes a code they can walk in with.
  Future<void> _fallBackToCounter({
    required String refundId,
    String? intentId,
    PaymentFailureCode? failureCode,
    required String reason,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        UPDATE refunds
           SET state = 'claim_issued',
               destination = 'agencyCash',
               claim_code = COALESCE(claim_code, @code),
               claim_expires_at = COALESCE(claim_expires_at,
                                           now() + interval '90 days'),
               reason = COALESCE(reason, '') ||
                        CASE WHEN reason IS NULL OR reason = '' THEN ''
                             ELSE ' — ' END || @why
         WHERE id = @id AND state IN ('approved', 'processing')
        RETURNING booking_id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, refundId),
        'code': TypedValue(Type.text, _claimCode(refundId)),
        'why': TypedValue(Type.text, reason),
      },
    );
    if (rows.isEmpty) return;

    if (intentId != null) {
      await tx.execute(
        Sql.named('''
          UPDATE payment_intents
             SET state = 'failed', terminal_at = now(),
                 failure_code = COALESCE(@failure, failure_code, 'psp_error')
           WHERE id = @id AND terminal_at IS NULL
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, intentId),
          'failure': TypedValue(Type.text, failureCode?.name),
        },
        ignoreRows: true,
      );
    }

    await _queueMessage(
      tx,
      bookingId: rows.first.toColumnMap()['booking_id'].toString(),
      event: 'booking.refunded',
    );
  });

  /// Queued, never sent here (ADR-0019). The drain owns delivery, and it reads
  /// the refund row to decide which of the two sentences this is.
  Future<void> _queueMessage(
    TxSession tx, {
    required String bookingId,
    required String event,
  }) => tx.execute(
    Sql.named('''
      INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                          dedupe_key)
      VALUES ('booking', @booking, @event,
              jsonb_build_object('bookingId', @booking::text),
              @event || ':' || @booking::text)
      ON CONFLICT (dedupe_key) DO NOTHING
    '''),
    parameters: {
      'booking': TypedValue(Type.uuid, bookingId),
      'event': TypedValue(Type.text, event),
    },
    ignoreRows: true,
  );

  /// Derived from the refund id rather than random, so a pass that crashes
  /// between issuing the code and committing it cannot hand out two.
  static String _claimCode(String refundId) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final digits = refundId.replaceAll(RegExp('[^0-9a-f]'), '');
    final buffer = StringBuffer('R');
    for (var i = 0; i < 7; i++) {
      buffer.write(
        alphabet[int.parse(digits[i * 2] + digits[i * 2 + 1], radix: 16) %
            alphabet.length],
      );
    }
    return buffer.toString();
  }

  static String _json(Map<String, Object?> raw) => jsonEncode(raw);
}
