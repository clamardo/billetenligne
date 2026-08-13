import 'package:bel_crypto/bel_crypto.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/second_factor.dart';
import '../db/database.dart';

/// Second factors, on the identity surface.
///
/// `DbScope.identity()` for every statement, because migration 0013 grants
/// `user_totp` to that role and to no other. Resolving a second factor happens
/// during sign-in, before the request has a tenant or a surface — the same
/// reason `auth_challenges` lives there.
///
/// **The seed is sealed here rather than in the domain.** A TOTP seed is the
/// one secret this system stores that it must be able to read back — the
/// server recomputes a code from it every thirty seconds — so hashing it, the
/// answer everywhere else, is not available. What is available is
/// authenticated encryption under a key that is not in the database, which
/// separates "somebody has a copy of the data" from "somebody has the
/// environment". Those are different events, and keeping them different is the
/// whole control; `SecretCipher` states what it is and is not worth.
///
/// `cipher` is nullable and that is a supported state: a local stack with no
/// key stores seeds in the clear, and the API says so at startup. A key that
/// appears later upgrades the rows as their owners sign in, which is why
/// reading here also writes.
final class PostgresSecondFactors implements SecondFactors {
  const PostgresSecondFactors(this._db, {SecretCipher? cipher})
    : _cipher = cipher;

  final Database _db;
  final SecretCipher? _cipher;

  static const _columns = '''
    t.user_id, t.secret, t.confirmed_at, t.last_window,
    t.failed_attempts, t.locked_until,
    (SELECT count(*)::int FROM user_totp_recovery r
      WHERE r.user_id = t.user_id
        AND r.used_at IS NULL
        AND r.superseded_at IS NULL) AS unused
  ''';

  @override
  Future<SecondFactor?> forUser(String userId) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('SELECT $_columns FROM user_totp t WHERE t.user_id = @id'),
          parameters: {'id': TypedValue(Type.uuid, userId)},
        );
        return rows.isEmpty ? null : _read(tx, rows.first.toColumnMap());
      });

  @override
  Future<SecondFactor?> beginEnrolment({
    required String userId,
    required String secretBase32,
    required List<String> recoveryHashes,
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    // `WHERE confirmed_at IS NULL` on the update path: a half-finished
    // enrolment is replaced, a live one is left alone. Silently overwriting a
    // confirmed factor would turn a stray click into a lockout of the person
    // whose phone still holds the old secret.
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO user_totp (user_id, secret)
        VALUES (@id, @secret)
        ON CONFLICT (user_id) DO UPDATE
           SET secret = EXCLUDED.secret,
               last_window = NULL,
               created_at = now()
         WHERE user_totp.confirmed_at IS NULL
        RETURNING user_id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, userId),
        'secret': TypedValue(Type.text, await _seal(secretBase32)),
      },
    );
    if (rows.isEmpty) return null;

    // Fresh codes for a fresh secret. The old ones are *retired* rather than
    // deleted: a code that unlocks a secret nobody holds is a key to a door
    // that no longer exists, but the row is evidence and `bel_identity` has
    // no DELETE here for exactly that reason.
    await tx.execute(
      Sql.named('''
        UPDATE user_totp_recovery
           SET superseded_at = now()
         WHERE user_id = @id AND used_at IS NULL AND superseded_at IS NULL
      '''),
      parameters: {'id': TypedValue(Type.uuid, userId)},
    );
    for (final hash in recoveryHashes) {
      // A collision with a retired code is astronomically unlikely and would
      // otherwise hand somebody seven codes instead of eight, silently. Revive
      // it as this enrolment's code rather than dropping it on the floor.
      await tx.execute(
        Sql.named('''
          INSERT INTO user_totp_recovery (user_id, code_hash)
          VALUES (@id, @hash)
          ON CONFLICT (user_id, code_hash) DO UPDATE
             SET used_at = NULL, superseded_at = NULL, created_at = now()
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, userId),
          'hash': TypedValue(Type.text, hash),
        },
      );
    }

    final read = await tx.execute(
      Sql.named('SELECT $_columns FROM user_totp t WHERE t.user_id = @id'),
      parameters: {'id': TypedValue(Type.uuid, userId)},
    );
    return _read(tx, read.first.toColumnMap());
  });

  @override
  Future<bool> confirm({required String userId, required int window}) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            UPDATE user_totp
               SET confirmed_at = now(), last_window = @window
             WHERE user_id = @id AND confirmed_at IS NULL
            RETURNING user_id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, userId),
            'window': TypedValue(Type.bigInteger, window),
          },
        );
        return rows.isNotEmpty;
      });

  @override
  Future<bool> spendWindow({required String userId, required int window}) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        // Conditional in SQL, not in Dart: two requests presenting the same
        // code at the same instant must produce one success, and only the
        // database can decide that.
        final rows = await tx.execute(
          Sql.named('''
            UPDATE user_totp
               SET last_window = @window,
                 failed_attempts = 0,
                 locked_until = NULL
             WHERE user_id = @id
               AND confirmed_at IS NOT NULL
               AND (last_window IS NULL OR last_window < @window)
            RETURNING user_id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, userId),
            'window': TypedValue(Type.bigInteger, window),
          },
        );
        return rows.isNotEmpty;
      });

  @override
  Future<bool> spendRecoveryCode({
    required String userId,
    required String codeHash,
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        UPDATE user_totp_recovery
           SET used_at = now()
         WHERE user_id = @id
           AND code_hash = @hash
           AND used_at IS NULL
           AND superseded_at IS NULL
        RETURNING id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, userId),
        'hash': TypedValue(Type.text, codeHash),
      },
    );
    if (rows.isEmpty) return false;

    // Clears the lock, exactly as spending a window does. A recovery code is
    // how somebody whose phone is gone proves themselves, and leaving them
    // locked after they succeeded would make the escape hatch useless in the
    // one situation it exists for — five wrong guesses on a handset they no
    // longer have.
    await tx.execute(
      Sql.named('''
        UPDATE user_totp
           SET failed_attempts = 0, locked_until = NULL
         WHERE user_id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, userId)},
    );
    return true;
  });

  @override
  Future<SecondFactor?> recordFailure({
    required String userId,
    required int lockAfter,
    required Duration lockFor,
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    // The count and the lock are decided in one statement, so two wrong
    // answers arriving together cannot each read "four" and each write
    // "five".
    await tx.execute(
      Sql.named('''
        UPDATE user_totp
           SET failed_attempts = failed_attempts + 1,
               locked_until = CASE
                 WHEN failed_attempts + 1 >= @after
                   THEN now() + make_interval(secs => @seconds)
                 ELSE locked_until
               END
         WHERE user_id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, userId),
        'after': TypedValue(Type.integer, lockAfter),
        'seconds': TypedValue(Type.double, lockFor.inSeconds.toDouble()),
      },
    );

    final rows = await tx.execute(
      Sql.named('SELECT $_columns FROM user_totp t WHERE t.user_id = @id'),
      parameters: {'id': TypedValue(Type.uuid, userId)},
    );
    return rows.isEmpty ? null : _read(tx, rows.first.toColumnMap());
  });

  @override
  Future<void> disable(String userId) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        await tx.execute(
          Sql.named('DELETE FROM user_totp WHERE user_id = @id'),
          parameters: {'id': TypedValue(Type.uuid, userId)},
        );
      });

  Future<String> _seal(String secretBase32) async =>
      _cipher == null ? secretBase32 : await _cipher.encrypt(secretBase32);

  /// Hydrates a row, and upgrades it in passing.
  ///
  /// **Reading writes, and only in one direction.** A row stored before a key
  /// existed carries no version prefix; it is returned as it stands — a reader
  /// that threw would lock out everybody enrolled before the deploy — and
  /// re-sealed in the same transaction, so the plaintext is gone the next time
  /// its owner signs in. Nothing goes the other way: a sealed row with no key
  /// configured throws rather than being unwrapped, because reverting a
  /// control by losing an environment variable should be an outage, not a
  /// silent downgrade.
  Future<SecondFactor> _read(TxSession tx, Map<String, dynamic> row) async {
    final stored = row['secret'] as String;
    final cipher = _cipher;

    final String secret;
    if (cipher == null) {
      if (SecretCipher.isSealed(stored)) {
        throw StateError(
          'A second factor is sealed and no key is configured. Set '
          'TOTP__ENCRYPTIONKEY to the key these rows were written with.',
        );
      }
      secret = stored;
    } else {
      secret = await cipher.decrypt(stored);
      if (!SecretCipher.isSealed(stored)) {
        await tx.execute(
          Sql.named('''
            UPDATE user_totp SET secret = @secret
             WHERE user_id = @id AND secret = @was
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, row['user_id'].toString()),
            'secret': TypedValue(Type.text, await cipher.encrypt(secret)),
            // Guarded on the value we read, so two concurrent sign-ins do not
            // each seal and leave the second overwriting the first.
            'was': TypedValue(Type.text, stored),
          },
          ignoreRows: true,
        );
      }
    }

    return SecondFactor(
      userId: row['user_id'].toString(),
      secretBase32: secret,
      confirmedAt: row['confirmed_at'] as DateTime?,
      lastWindow: row['last_window'] as int?,
      unusedRecoveryCodes: (row['unused'] as int?) ?? 0,
      failedAttempts: (row['failed_attempts'] as int?) ?? 0,
      lockedUntil: row['locked_until'] as DateTime?,
    );
  }
}
