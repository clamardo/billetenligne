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
  const SecureSessionStore({FlutterSecureStorage? storage, this.key = _key})
    : _storage =
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

  @override
  Future<String?> read() async {
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
    try {
      await _storage.delete(key: key);
    } on Object catch (e) {
      debugPrint('session store would not clear: $e');
    }
  }
}
