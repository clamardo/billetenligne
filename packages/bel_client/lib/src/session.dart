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
    Future<AccountDto?> Function()? probe,
    Future<void> Function()? endServerSession,
  }) : _firebase = firebase,
       _store = store ?? MemorySessionStore(),
       _clock = clock,
       _probe = probe,
       _endServerSession = endServerSession;

  final FirebaseIdentityClient _firebase;
  final SessionStore _store;
  final Clock _clock;

  /// Asks the server "am I signed in?" — the only way a browser can find out
  /// (J11).
  ///
  /// A cookie session leaves nothing on the page to inspect: the cookie is
  /// `HttpOnly` by design, so there is no local state to restore from and the
  /// answer has to be a request. Null on a surface that has no such session,
  /// which is every native build.
  final Future<AccountDto?> Function()? _probe;

  /// Ends the session on the **server**. A page that only forgot its cookie
  /// would leave a live session behind that anybody holding the old value
  /// could still spend.
  final Future<void> Function()? _endServerSession;

  /// True while this session lives in a cookie the page cannot read.
  ///
  /// Everything that would otherwise be a credential — the refresh token, the
  /// ID token — is on the server. What this object holds is a name and the
  /// fact that somebody is signed in.
  bool _cookie = false;

  bool get isCookieSession => _cookie;

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
  bool get isSignedIn => _session != null || _cookie;

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
    // The browser's shape: the server already exchanged, and what came back
    // with this response was a cookie this page cannot read. There is nothing
    // to exchange and nothing to store — which is the entire point.
    if (signIn.cookieSession) {
      _cookie = true;
      _session = null;
      _account = signIn.account;
      await _store.clear();
      _changes.add(_account);
      return;
    }

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

  /// [adopt], for the callers who have just spent a one-time code on it.
  ///
  /// Same work, different failure. By the time this is called our API has
  /// already accepted the six digits and consumed them, so nothing that goes
  /// wrong here can be answered by typing them again — which is exactly what
  /// the underlying [FirebaseRefused] ("Sign in to continue") tells the
  /// traveller to do. Wrapping it in [SignInNotCompleted] keeps that fact
  /// where it is known: here, not in a catch clause on a screen that cannot
  /// tell a refused code from a refused credential.
  ///
  /// The [StateError] for a session that still owes a second factor is left
  /// alone. It is a caller bug, not something to dress up as a failure the
  /// traveller can read.
  Future<void> adoptGranted(SessionDto signIn) async {
    try {
      await adopt(signIn);
    } on ApiFailure catch (failure) {
      throw SignInNotCompleted(failure);
    }
  }

  /// Restores a session at launch. True when there was one to restore.
  ///
  /// A failure here signs out rather than throwing: a refresh token that
  /// Firebase no longer accepts — revoked, expired, the account disabled — is
  /// a normal end to a session and must not be an error screen at startup.
  Future<bool> restore() async {
    final stored = await _store.read();

    // Nothing stored, but the browser may still be carrying a cookie. Asking
    // is the only way to find out: an `HttpOnly` cookie is invisible to this
    // code, which is what makes it worth having.
    if (stored == null || stored.isEmpty) {
      final probe = _probe;
      if (probe == null) return false;
      try {
        final account = await probe();
        if (account == null) return false;
        _cookie = true;
        _account = account;
        _changes.add(_account);
        return true;
      } on ApiFailure {
        // No session, or no network. Neither is an error at launch.
        return false;
      }
    }

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
    // A cookie session carries no bearer, on purpose. The browser attaches
    // the cookie itself and this code never sees a credential.
    if (_cookie) return null;

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
    // The server first, and only for a session it actually holds. Failing to
    // reach it must not leave somebody looking at a signed-in screen, so the
    // local half happens either way — and the server's own clock ends the
    // session regardless.
    if (_cookie && _endServerSession != null) {
      try {
        await _endServerSession();
      } on Object {
        // Offline, or already gone. Signing out twice is signing out.
      }
    }

    _cookie = false;
    _session = null;
    _account = null;
    await _store.clear();
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}
