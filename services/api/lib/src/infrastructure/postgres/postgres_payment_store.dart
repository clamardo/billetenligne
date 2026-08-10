import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/payment_store.dart';
import '../db/database.dart';

/// Payments, across two surfaces.
///
/// Opening an intent runs as the **traveller** — they own the booking, and
/// migration 0011's insert policy checks that the booking is theirs and still
/// `pending_payment`. Recording an outcome runs as the **platform**, because
/// `bel_public` has no UPDATE on `payment_intents` at all: there is no path
/// from an internet request to a captured payment, which is the same property
/// migration 0005 established for a sold seat.
final class PostgresPaymentStore implements PaymentStore {
  const PostgresPaymentStore(this._db);

  final Database _db;

  static const _columns = '''
    id, booking_id, operator_id, rail_id, msisdn, collection_msisdn,
    amount_minor, currency::text AS currency, state::text AS state,
    failure_code, rail_transaction_id, created_at, expires_at
  ''';

  @override
  Future<List<CollectionAccount>> collectionAccounts(String operatorId) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT rail_id, msisdn, display_name, verified_at
              FROM operator_payment_accounts
             WHERE operator_id = @operator AND active AND verified_at IS NOT NULL
             ORDER BY rail_id
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return [
          for (final row in rows)
            CollectionAccount(
              railId: row.toColumnMap()['rail_id'] as String,
              msisdn: row.toColumnMap()['msisdn'] as String,
              displayName: row.toColumnMap()['display_name'] as String,
              verified: true,
            ),
        ];
      });

  @override
  Future<PaymentIntentRecord?> open({
    required String bookingId,
    required String userId,
    required String railId,
    required String payerMsisdn,
    required bool payerIsAccountHolder,
    required String idempotencyKey,
    required Duration window,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    // A retry of the same attempt returns the SAME intent rather than opening
    // a second. `idempotency_keys` guards the route; this guards the row, and
    // both are needed — a duplicate tap that got past one must not get past
    // the other and charge somebody twice.
    final existing = await tx.execute(
      Sql.named(
        'SELECT $_columns FROM payment_intents WHERE idempotency_key = @key',
      ),
      parameters: {'key': TypedValue(Type.text, idempotencyKey)},
    );
    if (existing.isNotEmpty) return _record(existing.first.toColumnMap());

    // The booking, its operator, and the operator's collection account for
    // this rail — one query, because all three have to be true together and
    // checking them separately leaves a window between each pair.
    final context = await tx.execute(
      Sql.named('''
        SELECT b.operator_id, b.total_minor, b.currency::text AS currency,
               a.msisdn AS collection_msisdn
          FROM bookings b
          JOIN operator_payment_accounts a
            ON a.operator_id = b.operator_id
           AND a.rail_id = @rail
           AND a.active
           AND a.verified_at IS NOT NULL
         WHERE b.id = @booking
           AND b.purchaser_user_id = app_user_id()
           AND b.state = 'pending_payment'
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'rail': TypedValue(Type.text, railId),
      },
    );

    // Not theirs, already paid, or the operator has no verified account on
    // this rail. One answer: none is actionable beyond "choose again", and
    // distinguishing them would say whose booking it is.
    if (context.isEmpty) return null;

    final c = context.first.toColumnMap();

    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO payment_intents
          (booking_id, operator_id, rail_id, msisdn, collection_msisdn,
           payer_is_account_holder, amount_minor, currency, idempotency_key,
           expires_at)
        VALUES (@booking, @operator, @rail, @payer, @collection, @holder,
                @amount, @currency, @key,
                now() + make_interval(secs => @window))
        RETURNING $_columns
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, c['operator_id'].toString()),
        'rail': TypedValue(Type.text, railId),
        'payer': TypedValue(Type.text, payerMsisdn),
        // Captured now, not looked up at settlement. An operator who changes
        // their collection number on Tuesday must not silently redirect
        // Monday's in-flight payment.
        'collection': TypedValue(Type.text, c['collection_msisdn'] as String),
        'holder': TypedValue(Type.boolean, payerIsAccountHolder),
        'amount': TypedValue(Type.bigInteger, c['total_minor'] as int),
        'currency': TypedValue(Type.text, (c['currency'] as String).trim()),
        'key': TypedValue(Type.text, idempotencyKey),
        'window': TypedValue(Type.double, window.inSeconds.toDouble()),
      },
    );

    return _record(inserted.first.toColumnMap());
  });

  @override
  Future<PaymentIntentRecord?> byId({
    required String intentId,
    required String userId,
  }) => _db.transaction(DbScope.traveller(userId), (tx) async {
    final rows = await tx.execute(
      Sql.named('SELECT $_columns FROM payment_intents WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, intentId)},
    );
    return rows.isEmpty ? null : _record(rows.first.toColumnMap());
  });

  @override
  Future<PaymentIntentRecord?> recordOutcome({
    required String intentId,
    required PaymentState state,
    required String source,
    required Map<String, Object?> raw,
    PaymentFailureCode? failureCode,
    String? railTransactionId,
  }) => _db.transaction(const DbScope.worker(), (tx) async {
    // The event is written FIRST and unconditionally. Whether the transition
    // is legal is a separate question, and an illegal one is exactly the
    // event a dispute turns on.
    await tx.execute(
      Sql.named('''
        INSERT INTO payment_events (intent_id, source, raw)
        VALUES (@intent, @source, @raw)
      '''),
      parameters: {
        'intent': TypedValue(Type.uuid, intentId),
        'source': TypedValue(Type.text, source),
        'raw': TypedValue(Type.jsonb, raw),
      },
      ignoreRows: true,
    );

    final current = await tx.execute(
      Sql.named('SELECT $_columns FROM payment_intents WHERE id = @id FOR UPDATE'),
      parameters: {'id': TypedValue(Type.uuid, intentId)},
    );
    if (current.isEmpty) return null;

    final record = _record(current.first.toColumnMap());

    // The domain decides whether this move is legal. An out-of-order callback
    // arriving after a capture is a NORMAL event on these rails, and the right
    // answer is to keep the capture and say so — not to throw.
    final intent = PaymentIntent(
      id: record.id,
      bookingId: record.bookingId,
      railId: record.railId,
      amount: record.amount,
      state: record.state,
      createdAt: record.createdAt,
      // Not read by `transitionTo`; the row already carries the real one and
      // reading it back purely to satisfy a constructor would be a query for
      // nothing.
      idempotencyKey: record.id,
    );

    final moved = intent.transitionTo(
      state,
      now: DateTime.now().toUtc(),
      failureCode: failureCode,
    );

    if (moved case Err()) return record;

    final updated = await tx.execute(
      Sql.named('''
        UPDATE payment_intents
           SET state = @state::payment_state,
               failure_code = @failure,
               rail_transaction_id = COALESCE(@railTxn, rail_transaction_id),
               terminal_at = CASE
                 WHEN @state IN ('captured','failed','expired','cancelled')
                 THEN now() ELSE terminal_at END
         WHERE id = @id
        RETURNING $_columns
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, intentId),
        'state': TypedValue(Type.text, state.name),
        'failure': TypedValue(Type.text, failureCode?.name),
        'railTxn': TypedValue(Type.text, railTransactionId),
      },
    );

    return _record(updated.first.toColumnMap());
  });

  @override
  Future<List<PaymentIntentRecord>> inFlight({int limit = 100}) =>
      _db.transaction(const DbScope.worker(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT $_columns FROM payment_intents
             WHERE state IN ('pending', 'authorized')
             ORDER BY last_polled_at NULLS FIRST
             LIMIT @limit
          '''),
          parameters: {'limit': TypedValue(Type.integer, limit)},
        );
        return [for (final row in rows) _record(row.toColumnMap())];
      });

  @override
  Future<void> markPolled(String intentId) =>
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

  static PaymentIntentRecord _record(Map<String, dynamic> r) =>
      PaymentIntentRecord(
        id: r['id'].toString(),
        bookingId: r['booking_id'].toString(),
        operatorId: r['operator_id'].toString(),
        railId: r['rail_id'] as String,
        amount: Money(
          r['amount_minor'] as int,
          Currency.byCode((r['currency'] as String).trim())!,
        ),
        state: PaymentState.values.firstWhere(
          (s) => s.name == r['state'],
          orElse: () => PaymentState.created,
        ),
        payerMsisdn: r['msisdn'] as String? ?? '',
        collectionMsisdn: r['collection_msisdn'] as String? ?? '',
        createdAt: r['created_at'] as DateTime,
        expiresAt: r['expires_at'] as DateTime?,
        failureCode: r['failure_code'] == null
            ? null
            : PaymentFailureCode.values.firstWhere(
                (c) => c.name == r['failure_code'],
                orElse: () => PaymentFailureCode.pspUnavailable,
              ),
        railTransactionId: r['rail_transaction_id'] as String?,
      );
}
