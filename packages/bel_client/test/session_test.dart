import 'dart:convert';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A scripted Firebase. Records what was sent, which is where half the
/// assertions are — the exchange and the refresh use two different Google
/// APIs with two different field spellings, and sending the wrong body is the
/// failure that surfaces as an unexplained 401 three screens later.
final class _ScriptedFirebase extends http.BaseClient {
  _ScriptedFirebase(this._responses);

  final List<Object> _responses;
  final List<Uri> urls = [];
  final List<Map<String, Object?>> bodies = [];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    urls.add(request.url);
    bodies.add(
      jsonDecode((request as http.Request).body) as Map<String, Object?>,
    );

    final next = _responses[_index.clamp(0, _responses.length - 1)];
    _index++;
    if (next is Exception) throw next;

    final (status, body) = next as (int, String);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

final class _MovableClock implements Clock {
  _MovableClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

String _exchanged({String id = 'id-token-1', String refresh = 'refresh-1'}) =>
    jsonEncode({'idToken': id, 'refreshToken': refresh, 'expiresIn': '3600'});

String _refreshed({String id = 'id-token-2', String refresh = 'refresh-2'}) =>
    jsonEncode({
      'id_token': id,
      'refresh_token': refresh,
      'expires_in': '3600',
    });

SessionDto signInResponse() => const SessionDto(
  customToken: 'custom-token-from-our-api',
  isNewAccount: true,
  account: AccountDto(id: 'u-aline', language: 'fr', email: 'aline@example.cg'),
);

void main() {
  late _MovableClock clock;

  BelSession build(_ScriptedFirebase transport, {SessionStore? store}) =>
      BelSession(
        firebase: FirebaseIdentityClient(
          config: FirebaseClientConfig.emulator(),
          httpClient: transport,
          clock: clock,
        ),
        store: store,
        clock: clock,
      );

  setUp(() => clock = _MovableClock(DateTime.utc(2026, 8, 9, 6)));

  group('exchanging the custom token', () {
    test('turns our credential into a Firebase session', () async {
      final firebase = _ScriptedFirebase([(200, _exchanged())]);
      final session = build(firebase);

      await session.adopt(signInResponse());

      expect(session.isSignedIn, isTrue);
      expect(await session.token(), 'id-token-1');
      expect(session.account?.email, 'aline@example.cg');

      // The credential our API minted is what goes to Firebase — the whole
      // reason Firebase remains the identity provider even though we ran the
      // challenge ourselves (ADR-0024).
      expect(firebase.bodies.single['token'], 'custom-token-from-our-api');
      expect(firebase.bodies.single['returnSecureToken'], isTrue);
      expect(
        firebase.urls.single.toString(),
        contains(
          'identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken',
        ),
      );
    });

    test('the emulator is addressed on localhost, not Google', () async {
      final firebase = _ScriptedFirebase([(200, _exchanged())]);
      await build(firebase).adopt(signInResponse());

      // A `demo-` project on localhost, with no credentials and no way to
      // reach a real project by accident (ADR-0020).
      expect(firebase.urls.single.host, 'localhost');
      expect(firebase.urls.single.port, 9099);
    });

    test('persists the refresh token and nothing else', () async {
      final store = MemorySessionStore();
      await build(
        _ScriptedFirebase([(200, _exchanged())]),
        store: store,
      ).adopt(signInResponse());

      // The refresh token is the only thing worth keeping, and only in
      // platform secure storage. An ID token in a file is a bearer worth an
      // hour to whoever reads it.
      expect(await store.read(), 'refresh-1');
    });

    test('a refused exchange is not retryable', () async {
      final firebase = _ScriptedFirebase([
        (
          400,
          jsonEncode({
            'error': {'message': 'INVALID_CUSTOM_TOKEN'},
          }),
        ),
      ]);

      await expectLater(
        build(firebase).adopt(signInResponse()),
        throwsA(
          isA<FirebaseRefused>()
              .having((e) => e.reason, 'reason', 'INVALID_CUSTOM_TOKEN')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });
  });

  group('keeping the token fresh', () {
    test('refreshes when the token is about to expire', () async {
      final firebase = _ScriptedFirebase([
        (200, _exchanged()),
        (200, _refreshed()),
      ]);
      final session = build(firebase);
      await session.adopt(signInResponse());

      clock.advance(const Duration(minutes: 59, seconds: 30));
      expect(await session.token(), 'id-token-2');

      // The refresh endpoint answers in snake_case while the exchange answers
      // in camelCase. Two Google APIs, and reading the wrong field yields a
      // null that surfaces much later as an unexplained 401.
      expect(firebase.bodies.last['grant_type'], 'refresh_token');
      expect(firebase.bodies.last['refresh_token'], 'refresh-1');
      expect(
        firebase.urls.last.toString(),
        contains('securetoken.googleapis.com'),
      );
    });

    test(
      'a minute of headroom, because a 2G handshake takes seconds',
      () async {
        final firebase = _ScriptedFirebase([
          (200, _exchanged()),
          (200, _refreshed()),
        ]);
        final session = build(firebase);
        await session.adopt(signInResponse());

        clock.advance(const Duration(minutes: 58));
        expect(await session.token(), 'id-token-1', reason: 'still fresh');

        clock.advance(const Duration(minutes: 1, seconds: 30));
        expect(
          await session.token(),
          'id-token-2',
          reason: 'inside the headroom',
        );
      },
    );

    test('three screens waking at once produce one refresh', () async {
      final firebase = _ScriptedFirebase([
        (200, _exchanged()),
        (200, _refreshed()),
      ]);
      final session = build(firebase);
      await session.adopt(signInResponse());
      clock.advance(const Duration(hours: 1));

      final tokens = await Future.wait([
        session.token(),
        session.token(),
        session.token(),
      ]);

      // Firebase rotates the refresh token on use, so three concurrent
      // refreshes would race to invalidate each other's answer.
      expect(tokens, ['id-token-2', 'id-token-2', 'id-token-2']);
      expect(firebase.urls.length, 2, reason: 'one exchange, one refresh');
    });

    test('the rotated refresh token replaces the stored one', () async {
      final store = MemorySessionStore();
      final session = build(
        _ScriptedFirebase([(200, _exchanged()), (200, _refreshed())]),
        store: store,
      );
      await session.adopt(signInResponse());
      clock.advance(const Duration(hours: 1));
      await session.token();

      expect(await store.read(), 'refresh-2');
    });

    test('a revoked refresh token signs out rather than looping', () async {
      final session = build(
        _ScriptedFirebase([
          (200, _exchanged()),
          (
            400,
            jsonEncode({
              'error': {'message': 'TOKEN_EXPIRED'},
            }),
          ),
        ]),
      );
      await session.adopt(signInResponse());
      clock.advance(const Duration(hours: 1));

      expect(await session.token(), isNull);
      expect(session.isSignedIn, isFalse);
    });

    test('offline sends the stale token rather than nothing', () async {
      final session = build(
        _ScriptedFirebase([(200, _exchanged()), Exception('no route to host')]),
      );
      await session.adopt(signInResponse());
      clock.advance(const Duration(hours: 1));

      // It may well still be inside the server's leeway. The worst case is a
      // 401 the caller already handles; sending nothing guarantees one.
      expect(await session.token(), 'id-token-1');
      expect(session.isSignedIn, isTrue);
    });
  });

  group('across launches', () {
    test('a stored refresh token restores the session', () async {
      final store = MemorySessionStore();
      await store.write('refresh-from-last-launch');

      final firebase = _ScriptedFirebase([(200, _refreshed())]);
      final session = build(firebase, store: store);

      expect(await session.restore(), isTrue);
      expect(await session.token(), 'id-token-2');
      expect(
        firebase.bodies.single['refresh_token'],
        'refresh-from-last-launch',
      );
    });

    test('nothing stored is not an error', () async {
      final session = build(_ScriptedFirebase([(200, _refreshed())]));
      expect(await session.restore(), isFalse);
      expect(await session.token(), isNull);
    });

    test('a revoked token at launch signs out quietly', () async {
      final store = MemorySessionStore();
      await store.write('revoked');

      final session = build(
        _ScriptedFirebase([
          (
            401,
            jsonEncode({
              'error': {'message': 'USER_DISABLED'},
            }),
          ),
        ]),
        store: store,
      );

      // A normal end to a session, not an error screen at startup.
      expect(await session.restore(), isFalse);
      expect(await store.read(), isNull);
    });

    test('offline at launch keeps the token for the next attempt', () async {
      final store = MemorySessionStore();
      await store.write('still-good-probably');

      final session = build(
        _ScriptedFirebase([Exception('no route to host')]),
        store: store,
      );

      expect(await session.restore(), isFalse);
      // Discarding it would sign somebody out for having opened the app in a
      // tunnel.
      expect(await store.read(), 'still-good-probably');
    });
  });

  test('signing out clears the token and announces it', () async {
    final session = build(_ScriptedFirebase([(200, _exchanged())]));
    final seen = <AccountDto?>[];
    session.changes.listen(seen.add);

    await session.adopt(signInResponse());
    await session.signOut();
    await Future<void>.delayed(Duration.zero);

    expect(await session.token(), isNull);
    expect(seen.map((a) => a?.email), ['aline@example.cg', null]);
  });
}
