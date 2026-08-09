import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../../middleware/idempotency.dart';
import '../db/database.dart';

/// Idempotency backed by `idempotency_keys`.
///
/// The whole contract rests on one statement: `INSERT ... ON CONFLICT DO
/// NOTHING RETURNING`. It is atomic in a single round trip, which is what
/// makes two concurrent taps of the same button race *correctly* — exactly one
/// insert succeeds and the other sees the existing row. A read-then-write pair
/// would leave a window between them, and that window is precisely where a
/// duplicate charge lives.
///
/// [MemoryIdempotencyStore] mirrors this contract for unit tests, which is
/// what keeps those tests meaningful.
final class PostgresIdempotencyStore implements IdempotencyStore {
  const PostgresIdempotencyStore(this._db, {required this.scope});

  final Database _db;

  /// Which surface's connection to use. A traveller's key is written under the
  /// public role and an operator's under the tenant role, so neither can read
  /// or overwrite the other's.
  final DbScope scope;

  @override
  Future<IdempotencyRecord?> claim(
    String key,
    String requestHash,
    String scopeName,
  ) => _db.transaction(scope, (tx) async {
    final inserted = await tx.execute(
      Sql.named('''
        INSERT INTO idempotency_keys (key, scope, request_hash, user_id)
        VALUES (@key, @scope, @hash, app_user_id())
        ON CONFLICT (key) DO NOTHING
        RETURNING key
      '''),
      parameters: {
        'key': TypedValue(Type.text, key),
        'scope': TypedValue(Type.text, scopeName),
        'hash': TypedValue(Type.text, requestHash),
      },
    );

    // We claimed it. The caller does the work.
    if (inserted.isNotEmpty) return null;

    final existing = await tx.execute(
      Sql.named('''
        SELECT key, request_hash, status_code, response_body
          FROM idempotency_keys
         WHERE key = @key
      '''),
      parameters: {'key': TypedValue(Type.text, key)},
    );

    // Inserted nothing and found nothing means one of two things: the row was
    // swept between the two statements, or the key belongs to a different
    // traveller and RLS is hiding it. Both are answered correctly by treating
    // this as a fresh claim — the second case then fails on the unique index
    // downstream, where it can be reported as what it actually is.
    if (existing.isEmpty) return null;

    final r = existing.first.toColumnMap();
    return IdempotencyRecord(
      key: r['key'] as String,
      requestHash: r['request_hash'] as String,
      statusCode: r['status_code'] as int?,
      responseBody: switch (r['response_body']) {
        final Map<String, Object?> m => m,
        final String s => jsonDecode(s) as Map<String, Object?>,
        _ => null,
      },
    );
  });

  @override
  Future<void> complete(
    String key,
    int statusCode,
    Map<String, Object?> body,
  ) => _db.transaction(scope, (tx) async {
    await tx.execute(
      Sql.named('''
        UPDATE idempotency_keys
           SET status_code = @status, response_body = @body
         WHERE key = @key
      '''),
      parameters: {
        'key': TypedValue(Type.text, key),
        'status': TypedValue(Type.integer, statusCode),
        'body': TypedValue(Type.jsonb, body),
      },
      ignoreRows: true,
    );
  });

  @override
  Future<void> release(String key) => _db.transaction(scope, (tx) async {
    // Only an unfinished claim is released. Deleting a completed row would
    // turn a replay into a second execution, which is the one thing this
    // table exists to prevent.
    await tx.execute(
      Sql.named(
        'DELETE FROM idempotency_keys WHERE key = @key AND status_code IS NULL',
      ),
      parameters: {'key': TypedValue(Type.text, key)},
      ignoreRows: true,
    );
  });
}
