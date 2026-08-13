# bel_secure_store

Where a refresh token lives between launches on a handset: the iOS **Keychain**
and Keystore-backed **`EncryptedSharedPreferences`** on Android (ADR-0013).

One package rather than a copy in each app, for the same reason the
second-factor screen is one widget: two implementations of one security control
is two chances for one of them to be wrong, and the wrong one is the one nobody
looks at again.

```dart
final session = BelSession(
  firebase: FirebaseIdentityClient(config: ...),
  store: const SecureSessionStore(),
);
```

## The two decisions in it

**After the first unlock, not on every unlock.** The app is launched at 04:30
by somebody who has not looked at their phone yet. A token the Keychain will
not release until the screen has been unlocked once more is a traveller signing
in again at a coach door.

**Every failure is "not signed in", never a crash.** The Android Keystore
genuinely loses keys — a restored backup, a fingerprint reset, a vendor ROM —
and the standard symptom is a decrypt error on read. A launch that throws there
is an app that can never start again on that handset. So the token is
forgotten and the sign-in screen is shown, which is a nuisance rather than a
brick. An unwritable store does not fail a sign-in either: the session is held
in memory for this launch either way, and what is lost is only its surviving a
restart.

## Not for web

`flutter_secure_storage` has a web implementation and **it is not secure
storage**: it puts an AES key in `localStorage` next to the value it encrypts.
That is obfuscation wearing the word *secure*, and shipping it would make the
console look protected while being no better than a plain string.

The honest equivalent on web is a same-site, HTTP-only cookie set by the
server, which is a server slice rather than a client one. Until then the
console and the admin app hold their session in memory and it ends when the tab
closes — written down in both `main.dart` files rather than dressed up.

## Tests

```bash
flutter test
```

A test host has no Keychain, so the platform channel is scripted. What is
asserted is the half that is ours: which options we ask for, and what the app
does when the platform says no.
