import 'dart:convert';
import 'dart:math';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:postgres/postgres.dart';

import '../../application/ports/token_exchange.dart';
import '../../application/ports/web_sessions.dart';
import '../db/database.dart';

/// Browser sessions, on the identity surface (migration 0053).
///
/// `DbScope.identity()` for every statement: resolving a session happens
/// before a request has a tenant or a surface, exactly as signing in does.
///
/// **The interesting line in this file is `FOR UPDATE`.** Firebase rotates the
/// refresh token every time it is spent, so two tabs that wake together and
/// both find an expired ID token must not both spend it — the loser's answer
/// is a token Firebase has already invalidated, and the person is signed out
/// for having opened a second tab. Taking the row's lock makes the second tab
/// wait and then find the token the first one stored, which costs a few
/// milliseconds once an hour and removes the whole class of failure.
final class PostgresWebSessions implements WebSessions {
  PostgresWebSessions(
    this._db, {
    required TokenExchange exchange,
    SecretCipher? cipher,
    Clock clock = const SystemClock(),
    Random? random,
  }) : _exchange = exchange,
       _cipher = cipher,
       _clock = clock,
       _random = random ?? Random.secure();

  final Database _db;
  final TokenExchange _exchange;

  /// Null on a local stack with no key, which stores the token in the clear
  /// and says so at startup — the same supported state `PostgresSecondFactors`
  /// documents. A key that appears later upgrades rows as they are used.
  final SecretCipher? _cipher;

  final Clock _clock;
  final Random _random;

  /// How long before an ID token expires we bother refreshing it.
  ///
  /// A token that dies thirty seconds into a request is a request that fails
  /// for no reason anybody can act on. A minute is longer than any call this
  /// API makes and shorter than the hour Firebase gives us.
  static const skew = Duration(minutes: 1);

  @override
  Future<String> open({
    required String userId,
    required String refreshToken,
    required String idToken,
    required DateTime idTokenExpiresAt,
    required Duration ttl,
    String? userAgent,
    String? ip,
  }) async {
    final selector = _mintSelector();

    await _db.transaction(const DbScope.identity(), (tx) async {
      await tx.execute(
        Sql.named('''
          INSERT INTO web_sessions
            (user_id, selector_hash, refresh_cipher,
             id_token_cipher, id_token_expires_at,
             user_agent, created_ip, expires_at)
          VALUES (@user, @hash, @refresh, @id, @idExpires,
                  @agent, @ip::inet, @expires)
        '''),
        parameters: {
          'user': TypedValue(Type.uuid, userId),
          'hash': TypedValue(Type.text, _hash(selector)),
          'refresh': TypedValue(Type.text, await _seal(refreshToken)),
          'id': TypedValue(Type.text, await _seal(idToken)),
          'idExpires': TypedValue(Type.timestampTz, idTokenExpiresAt),
          // Truncated: a user agent is a hint for a person reading their own
          // session list, not a fingerprint worth keeping in full.
          'agent': TypedValue(
            Type.text,
            userAgent == null || userAgent.isEmpty
                ? null
                : userAgent.substring(0, min(userAgent.length, 200)),
          ),
          'ip': TypedValue(Type.text, ip),
          'expires': TypedValue(Type.timestampTz, _clock.now().add(ttl)),
        },
      );
    });

    return selector;
  }

  @override
  Future<WebSessionToken?> resolve(String selector) => _db.transaction(
    const DbScope.identity(),
    (tx) async {
      final now = _clock.now();

      // `FOR UPDATE` and not a plain read. See the class comment: this lock
      // is what stops two tabs racing to spend one refresh token.
      final rows = await tx.execute(
        Sql.named('''
            SELECT id, user_id, refresh_cipher,
                   id_token_cipher, id_token_expires_at
              FROM web_sessions
             WHERE selector_hash = @hash
               AND revoked_at IS NULL
               AND expires_at > @now
             FOR UPDATE
          '''),
        parameters: {
          'hash': TypedValue(Type.text, _hash(selector)),
          'now': TypedValue(Type.timestampTz, now),
        },
      );
      if (rows.isEmpty) return null;

      final row = rows.first.toColumnMap();
      final id = row['id'].toString();
      final userId = row['user_id'].toString();

      final expiresAt = row['id_token_expires_at'] as DateTime?;
      final stored = row['id_token_cipher'] as String?;
      if (stored != null &&
          expiresAt != null &&
          expiresAt.isAfter(now.add(skew))) {
        await _touch(tx, id, now);
        return WebSessionToken(idToken: await _open(stored), userId: userId);
      }

      final ExchangedSession fresh;
      try {
        fresh = await _exchange.refresh(
          await _open(row['refresh_cipher'] as String),
        );
      } on TokenExchangeRefused {
        // Firebase says this session is over — the account was disabled, or
        // the token was revoked from elsewhere. Ending it here rather than
        // leaving a row that fails the same way on every request.
        await tx.execute(
          Sql.named('UPDATE web_sessions SET revoked_at = @now WHERE id = @id'),
          parameters: {
            'id': TypedValue(Type.uuid, id),
            'now': TypedValue(Type.timestampTz, now),
          },
        );
        return null;
      } on Object {
        // Google unreachable. Not this session's fault and not its end: the
        // caller gets a 401 for this request and the row is left alone.
        return null;
      }

      await tx.execute(
        Sql.named('''
            UPDATE web_sessions
               SET refresh_cipher = @refresh,
                   id_token_cipher = @id,
                   id_token_expires_at = @idExpires,
                   last_used_at = @now
             WHERE id = @row
          '''),
        parameters: {
          'row': TypedValue(Type.uuid, id),
          'refresh': TypedValue(Type.text, await _seal(fresh.refreshToken)),
          'id': TypedValue(Type.text, await _seal(fresh.idToken)),
          'idExpires': TypedValue(Type.timestampTz, now.add(fresh.expiresIn)),
          'now': TypedValue(Type.timestampTz, now),
        },
      );

      return WebSessionToken(idToken: fresh.idToken, userId: userId);
    },
  );

  @override
  Future<bool> revoke(String selector) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            UPDATE web_sessions SET revoked_at = @now
             WHERE selector_hash = @hash AND revoked_at IS NULL
             RETURNING id
          '''),
          parameters: {
            'hash': TypedValue(Type.text, _hash(selector)),
            'now': TypedValue(Type.timestampTz, _clock.now()),
          },
        );
        return rows.isNotEmpty;
      });

  @override
  Future<int> revokeAllFor(String userId) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            UPDATE web_sessions SET revoked_at = @now
             WHERE user_id = @user AND revoked_at IS NULL
             RETURNING id
          '''),
          parameters: {
            'user': TypedValue(Type.uuid, userId),
            'now': TypedValue(Type.timestampTz, _clock.now()),
          },
        );
        return rows.length;
      });

  Future<void> _touch(TxSession tx, String id, DateTime now) => tx.execute(
    Sql.named('UPDATE web_sessions SET last_used_at = @now WHERE id = @id'),
    parameters: {
      'id': TypedValue(Type.uuid, id),
      'now': TypedValue(Type.timestampTz, now),
    },
  );

  Future<String> _seal(String value) async =>
      _cipher == null ? value : await _cipher.encrypt(value);

  Future<String> _open(String stored) async =>
      _cipher == null ? stored : await _cipher.decrypt(stored);

  /// 32 bytes from the platform's own CSPRNG, base64url without padding.
  ///
  /// The whole security of a cookie session is that this value cannot be
  /// guessed: it is the only thing a browser presents. `Random.secure()`
  /// rather than `Random()`, which on this platform is a seeded PRNG somebody
  /// with two samples can continue.
  String _mintSelector() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static String _hash(String selector) =>
      crypto.sha256.convert(utf8.encode(selector)).toString();
}
