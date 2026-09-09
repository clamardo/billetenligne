import 'package:bel_client/bel_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The refresh token, in the Keychain or the Keystore (ADR-0013).
///
/// A refresh token is a ninety-day credential. Shared preferences would put it
/// in a file any other app on a rooted handset can read, and these handsets
/// are shared, resold and rooted far more often than the ones this kind of
/// decision usually gets made on. So: `kSecAttrAccessibleAfterFirstUnlock` on
/// iOS, and `EncryptedSharedPreferences` — which is Keystore-backed — on
/// Android.
///
/// **After first unlock, not on every unlock.** The app is launched at 04:30
/// by somebody who has not looked at their phone yet, and a token the
/// Keychain will not release until the screen has been unlocked once more is
/// a traveller signing in again at a coach door.
///
/// **Every failure here is "not signed in", never a crash.** The Android
/// Keystore genuinely loses keys — a restored backup, a fingerprint reset, a
/// vendor ROM — and the standard failure is a decrypt error on read. A launch
/// that throws on that is an app that can never start again on that handset;
/// the honest recovery is to forget the token and show the sign-in screen,
/// which is a nuisance rather than a brick.
final class SecureSessionStore implements SessionStore {
  const SecureSessionStore({
    FlutterSecureStorage? storage,
    this.key = _key,
    this.onWeb = kIsWeb,
  }) : _storage =
           storage ??
           const FlutterSecureStorage(aOptions: android, iOptions: ios);

  static const _key = 'bel.session.refresh';

  /// Keystore-backed rather than a plain preferences file, which anything on
  /// a rooted handset can read.
  static const android = AndroidOptions(encryptedSharedPreferences: true);

  /// After the *first* unlock, not on every one. Public so it can be asserted
  /// on: a test host has no Keychain, and this is the half of the decision
  /// that is ours.
  static const ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  final FlutterSecureStorage _storage;
  final String key;

  /// **Nothing is stored on the web** (J11, known gap #4).
  ///
  /// `flutter_secure_storage` has a web implementation, and it is not secure
  /// storage: it puts an AES key in `localStorage` beside the ciphertext it
  /// protects, which is a locked door with the key hanging on it. Anything
  /// that can read one can read the other, so what it actually provides is
  /// obfuscation wearing the word *secure* — and the thing being obfuscated
  /// is a ninety-day credential.
  ///
  /// The browser's answer is the `HttpOnly` cookie the server sets, which
  /// this page cannot read at all. So on web every method here is a no-op and
  /// [read] answers "not signed in", which sends the app down the cookie path
  /// rather than a false one.
  ///
  /// A parameter rather than a bare `kIsWeb` so the refusal is testable off
  /// the web, where every test in this repository runs.
  final bool onWeb;

  @override
  Future<String?> read() async {
    if (onWeb) return null;
    try {
      return await _storage.read(key: key);
    } on Object catch (e) {
      // Unreadable is not signed in. Clearing as well, because a value that
      // cannot be decrypted will not start decrypting tomorrow and leaving it
      // there means taking this path on every launch forever.
      debugPrint('session store unreadable, forgetting it: $e');
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(String refreshToken) async {
    if (onWeb) {
      // Deliberately silent about the token itself, and said once: a build
      // that reaches here is a web build, and the session it is being handed
      // belongs in a cookie.
      debugPrint('web build: the refresh token is not stored on this page');
      return;
    }
    try {
      await _storage.write(key: key, value: refreshToken);
    } on Object catch (e) {
      // The session still works for this launch — it is held in memory by
      // BelSession either way. What is lost is only the surviving of a
      // restart, which is not worth failing a sign-in over.
      debugPrint('session store unwritable, this session ends at exit: $e');
    }
  }

  @override
  Future<void> clear() async {
    if (onWeb) return;
    try {
      await _storage.delete(key: key);
    } on Object catch (e) {
      debugPrint('session store would not clear: $e');
    }
  }
}
