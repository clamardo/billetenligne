@Tags(['integration'])
library;

import 'package:bel_api/src/adapters/fake_token_exchange.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_web_sessions.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The session a browser holds no credential for (J11), against real SQL.
///
/// Three claims cannot be tested anywhere but here:
///
///   * **Two tabs do not race.** Firebase rotates the refresh token on every
///     use, so two tabs that wake together and both find an expired ID token
///     must not both spend it — the loser's token is already invalid and the
///     person is signed out for having opened a second tab. The control is
///     `SELECT … FOR UPDATE`, which is a database behaviour and nothing else.
///   * **Signing out ends it on the server**, not only in the browser. A page
///     that merely forgot its cookie leaves a session anybody holding the old
///     value can still spend.
///   * **The cookie's value is not what is stored.** A dump of this table
///     must let nobody in.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late String userId;

  /// A clock the test moves, so an expiry can be reached without waiting.
  final clock = _Moving(DateTime.now().toUtc());

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 6);
    userId = await fixture.traveller('7311');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  PostgresWebSessions sessions(FakeTokenExchange exchange) =>
      PostgresWebSessions(
        db,
        exchange: exchange,
        // The same key the second factor's seeds take. Present here so the
        // stored token is proven to be ciphertext rather than the value.
        cipher: SecretCipher.fromPassphrase(
          'an-integration-test-key-of-at-least-32-chars',
        ),
        clock: clock,
      );

  /// A session opened the way the route opens one: exchange first, store what
  /// came back. Going straight to `open` with an invented refresh token would
  /// make every later refresh fail for a reason the product does not have.
  Future<String> open(
    PostgresWebSessions store,
    FakeTokenExchange exchange, {
    Duration idTokenLife = const Duration(hours: 1),
  }) async {
    final exchanged = await exchange.exchangeCustomToken('fake:traveller');
    return store.open(
      userId: userId,
      refreshToken: exchanged.refreshToken,
      idToken: exchanged.idToken,
      idTokenExpiresAt: clock.now().add(idTokenLife),
      ttl: const Duration(days: 30),
    );
  }

  group('opening one', () {
    test('the selector is not what is stored', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(store, exchange);

      final rows = await fixture.rows(
        'SELECT selector_hash, refresh_cipher FROM web_sessions',
      );
      final stored = rows.map((r) => r['selector_hash']).toList();

      // A hash, the same rule `auth_challenges.code_hash` follows: a dump of
      // this table lets nobody in.
      expect(stored, isNot(contains(selector)));
      expect(selector.length, greaterThanOrEqualTo(32));

      // And the refresh token is ciphertext, not the token.
      final ciphers = rows.map((r) => '${r['refresh_cipher']}').toList();
      expect(ciphers.any((c) => c.contains('refresh-')), isFalse);
      expect(ciphers.any((c) => c.startsWith('v1.')), isTrue);
    });

    test('a live session resolves to a bearer', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(store, exchange);

      final resolved = await store.resolve(selector);

      expect(resolved, isNotNull);
      expect(resolved!.idToken, 'fake:traveller');
      expect(resolved.userId, userId);
    });

    test('a selector nobody minted resolves to nothing', () async {
      final store = sessions(FakeTokenExchange());

      // One answer for unknown, revoked and expired. Distinguishing them
      // tells somebody holding a guessed cookie which guess was closer.
      expect(await store.resolve('not-a-selector'), isNull);
    });
  });

  group('keeping it alive', () {
    test('a fresh token is reused rather than refreshed', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(store, exchange);

      await store.resolve(selector);
      await store.resolve(selector);

      // A console page making six calls costs one refresh, not six.
      expect(exchange.refreshes, isEmpty);
    });

    test('an expired token is refreshed, and the new one is kept', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(
        store,
        exchange,
        idTokenLife: const Duration(hours: 1),
      );

      clock.instant = clock.instant.add(const Duration(hours: 2));
      final refreshed = await store.resolve(selector);

      expect(refreshed, isNotNull);
      expect(exchange.refreshes, ['refresh-0']);

      // The rotated refresh token was stored: Firebase invalidates the old
      // one, so a session that kept it would end at the next refresh.
      final again = await store.resolve(selector);
      expect(again, isNotNull);
      expect(exchange.refreshes, hasLength(1), reason: 'still fresh');
    });

    test('two tabs waking together produce one refresh', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(
        store,
        exchange,
        idTokenLife: const Duration(hours: 1),
      );

      clock.instant = clock.instant.add(const Duration(hours: 2));

      // Both in flight at once, which is a Tuesday morning with the console
      // open in two tabs. Without the row lock the second spends a token the
      // first has already rotated away, and somebody is signed out for having
      // opened a second tab.
      final answers = await Future.wait([
        store.resolve(selector),
        store.resolve(selector),
      ]);

      expect(answers.every((a) => a != null), isTrue);
      expect(exchange.refreshes, hasLength(1));
    });

    test('a refresh Firebase refuses ends the session', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(
        store,
        exchange,
        idTokenLife: const Duration(hours: 1),
      );

      // Spent from somewhere else — another device signing out, the account
      // disabled. Firebase answers the same way to the copy this row holds.
      await exchange.refresh(exchange.live.single);
      exchange.refreshes.clear();

      clock.instant = clock.instant.add(const Duration(hours: 2));
      expect(await store.resolve(selector), isNull);

      // And the row is closed rather than left to fail the same way on every
      // request for thirty days.
      final rows = await fixture.rows(
        'SELECT revoked_at FROM web_sessions ORDER BY created_at DESC LIMIT 1',
      );
      expect(rows.single['revoked_at'], isNotNull);
    });
  });

  group('ending it', () {
    test('signing out ends it on the server', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(store, exchange);

      expect(await store.revoke(selector), isTrue);

      // Not "the browser forgot": anybody holding the old cookie value gets
      // nothing, which is the difference this slice exists for.
      expect(await store.resolve(selector), isNull);
    });

    test('signing out twice is signing out', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(store, exchange);

      await store.revoke(selector);
      expect(await store.revoke(selector), isFalse);
    });

    test('a stolen laptop ends every session at once', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final a = await open(store, exchange);
      final b = await open(store, exchange);

      final ended = await store.revokeAllFor(userId);

      expect(ended, greaterThanOrEqualTo(2));
      expect(await store.resolve(a), isNull);
      expect(await store.resolve(b), isNull);
    });

    test('a session past its own expiry is over', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      final selector = await open(store, exchange);

      // A browser cookie can outlive any intention — a shared machine, a
      // laptop that changed hands — so the server keeps its own clock on it.
      clock.instant = clock.instant.add(const Duration(days: 31));

      expect(await store.resolve(selector), isNull);
    });
  });

  group('the surface it runs on', () {
    test('the public role cannot read a session row', () async {
      final exchange = FakeTokenExchange();
      final store = sessions(exchange);
      await open(store, exchange);

      // Migration 0053: identity and nothing else. A session row is a live
      // credential in every sense that matters.
      final public = Database.open(PgFixture.appUrl, maxConnections: 2);
      addTearDown(public.close);

      await expectLater(
        public.transaction(
          const DbScope.anonymous(),
          (tx) => tx.execute('SELECT count(*) FROM web_sessions'),
        ),
        throwsA(anything),
      );
    });
  });
}

/// A clock the test moves by hand, so an hour can pass in a microsecond.
final class _Moving implements Clock {
  _Moving(this.instant);
  DateTime instant;
  @override
  DateTime now() => instant;
}
