import 'dart:async';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'api_failure.dart';
import 'firebase_identity_client.dart';

/// Where the refresh token lives between launches.
///
/// A port, because the answer differs per surface and only one of them is
/// safe: the app uses the Keychain and the Android Keystore (ADR-0013), and
/// tests use memory. Writing it to shared preferences would put a 90-day
/// credential in a file any other app on a rooted handset can read.
abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String refreshToken);
  Future<void> clear();
}

/// Memory. Tests, and the debug builds that should not persist anything.
final class MemorySessionStore implements SessionStore {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String refreshToken) async => _value = refreshToken;

  @override
  Future<void> clear() async => _value = null;
}

/// Holds the traveller's session and keeps its token fresh.
///
/// Deliberately knows nothing about the API beyond the token: it takes the
/// [SessionDto] our sign-in endpoint returned, exchanges the custom token
/// inside it with Firebase, and from then on answers one question — "what
/// bearer should this request carry?".
///
/// That question is asked *per request*, through [token], rather than answered
/// once at construction. Tokens expire mid-session, and a client holding a
/// stale copy fails the one call that mattered — which on this funnel is
/// usually the hold.
final class BelSession {
  BelSession({
    required FirebaseIdentityClient firebase,
    SessionStore? store,
    Clock clock = const SystemClock(),
  }) : _firebase = firebase,
       _store = store ?? MemorySessionStore(),
       _clock = clock;

  final FirebaseIdentityClient _firebase;
  final SessionStore _store;
  final Clock _clock;

  final _changes = StreamController<AccountDto?>.broadcast();

  FirebaseSession? _session;
  AccountDto? _account;

  /// In-flight refresh, shared. Three screens waking at once must produce one
  /// refresh, not three — and Firebase rotates the refresh token on use, so
  /// three concurrent refreshes would race to invalidate each other's answer.
  Future<FirebaseSession>? _refreshing;

  /// Emits on sign-in and sign-out. Null means signed out.
  Stream<AccountDto?> get changes => _changes.stream;

  AccountDto? get account => _account;
  bool get isSignedIn => _session != null;

  /// Adopts the answer to a correct code.
  ///
  /// The exchange happens here rather than being deferred, because a custom
  /// token is short-lived and a traveller who signs in and then loses signal
  /// should have a *refresh* token in hand, not a credential that expires in
  /// an hour and cannot be renewed.
  ///
  /// Throws on a response that still owes a second factor. That is a caller
  /// bug rather than a runtime condition — the sign-in flow is what decides
  /// between "adopt this" and "ask for six digits" — and it throws here so
  /// the bug surfaces in the first test that makes it, rather than as a
  /// session nobody was granted.
  Future<void> adopt(SessionDto signIn) async {
    final token = signIn.customToken;
    if (token == null) {
      throw StateError(
        'This sign-in still owes a second factor. Exchange its mfaToken at '
        'verifySecondFactor first.',
      );
    }

    _session = await _firebase.exchangeCustomToken(token);
    _account = signIn.account;
    await _store.write(_session!.refreshToken);
    _changes.add(_account);
  }

  /// Restores a session at launch. True when there was one to restore.
  ///
  /// A failure here signs out rather than throwing: a refresh token that
  /// Firebase no longer accepts — revoked, expired, the account disabled — is
  /// a normal end to a session and must not be an error screen at startup.
  Future<bool> restore() async {
    final stored = await _store.read();
    if (stored == null || stored.isEmpty) return false;

    try {
      _session = await _firebase.refresh(stored);
      await _store.write(_session!.refreshToken);
      return true;
    } on FirebaseRefused {
      await signOut();
      return false;
    } on ApiFailure {
      // Offline at launch. The stored token is kept — it is very probably
      // still good — and the next call that needs a bearer tries again.
      return false;
    }
  }

  /// The bearer for the next request, refreshing if it is about to expire.
  ///
  /// Null rather than throwing when nobody is signed in: browsing is open
  /// (ADR-0013), so most calls that pass through here legitimately have no
  /// token at all.
  Future<String?> token() async {
    final current = _session;
    if (current == null) return null;
    if (current.isFreshAt(_clock.now())) return current.idToken;

    try {
      final refreshed = await (_refreshing ??= _firebase.refresh(
        current.refreshToken,
      ));
      _session = refreshed;
      await _store.write(refreshed.refreshToken);
      return refreshed.idToken;
    } on FirebaseRefused {
      await signOut();
      return null;
    } on ApiFailure {
      // Offline, with a token that is stale but may well still be inside the
      // server's leeway. Sending it is a better bet than sending nothing: the
      // worst case is a 401 the caller already handles, and the alternative
      // guarantees one.
      return current.idToken;
    } finally {
      _refreshing = null;
    }
  }

  /// Called when the API answers 401 on a request that carried a token.
  ///
  /// The token verified against Firebase and was refused by us, which means
  /// the account is gone or disabled — a state no amount of refreshing fixes.
  Future<void> invalidate() => signOut();

  Future<void> signOut() async {
    _session = null;
    _account = null;
    await _store.clear();
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
