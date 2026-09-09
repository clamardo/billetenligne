import 'package:bel_secure_store/bel_secure_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session store against a scripted platform channel.
///
/// There is no Keychain on a test host, so what is exercised here is the half
/// that is ours: the options we ask for, and — the reason this file exists —
/// what happens when the platform says no. The Android Keystore genuinely
/// loses keys after a restored backup or a fingerprint reset, and an app that
/// throws on that path is one that can never start again on that handset.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  final calls = <MethodCall>[];
  late Object? Function(MethodCall) respond;

  void script(Object? Function(MethodCall) handler) => respond = handler;

  setUp(() {
    calls.clear();
    respond = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final answer = respond(call);
          if (answer is Exception) throw answer;
          return answer;
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('a token written is a token read back', () async {
    final stored = <String, String>{};
    script((call) {
      final key = (call.arguments as Map)['key'] as String;
      return switch (call.method) {
        'write' => stored[key] = (call.arguments as Map)['value'] as String,
        'read' => stored[key],
        'delete' => stored.remove(key),
        _ => null,
      };
    });

    const store = SecureSessionStore();
    await store.write('refresh-token');

    expect(await store.read(), 'refresh-token');

    await store.clear();
    expect(await store.read(), isNull);
  });

  // Asserted on the options rather than on the call, because a test host has
  // no Keychain and the plugin picks its options from the platform it is
  // running on. What is ours is which options we asked for.
  test('it asks for the Keystore, and for after-first-unlock', () {
    // Keystore-backed rather than a plain preferences file, which anything on
    // a rooted handset can read.
    expect(
      SecureSessionStore.android.toMap()['encryptedSharedPreferences'],
      'true',
    );
    // Not `unlocked`: the app is launched at 04:30 by somebody who has not
    // looked at their phone yet, and a token the Keychain withholds until the
    // next unlock is a traveller signing in again at a coach door.
    expect(SecureSessionStore.ios.toMap()['accessibility'], 'first_unlock');
  });

  test(
    'a platform that cannot read is not signed in, and is not a crash',
    () async {
      var deleted = false;
      script(
        (call) => switch (call.method) {
          'read' => Exception('BAD_DECRYPT'),
          'delete' => deleted = true,
          _ => null,
        },
      );

      const store = SecureSessionStore();

      expect(await store.read(), isNull);
      // And forgotten, because a value that will not decrypt today will not
      // start decrypting tomorrow — leaving it there takes this path on every
      // launch forever.
      expect(deleted, isTrue);
    },
  );

  test('a platform that cannot write still lets somebody sign in', () async {
    script(
      (call) => call.method == 'write' ? Exception('KEYSTORE_GONE') : null,
    );

    const store = SecureSessionStore();

    // No throw. The session is held in memory by BelSession either way; what
    // is lost is only its surviving a restart, and failing the sign-in over
    // that would be the larger harm.
    await expectLater(store.write('refresh-token'), completes);
  });

  test('a store that will not clear does not block a sign-out', () async {
    script((call) => call.method == 'delete' ? Exception('LOCKED') : null);

    await expectLater(const SecureSessionStore().clear(), completes);
  });

  group('on the web, nothing is stored at all', () {
    // `flutter_secure_storage` has a web implementation and it is not secure
    // storage: an AES key in `localStorage` beside the ciphertext it
    // protects. The browser's answer is the server's `HttpOnly` cookie (J11),
    // which this page cannot read — so the honest behaviour here is to keep
    // nothing and say "not signed in".
    const web = SecureSessionStore(onWeb: true);

    test('a write reaches no storage', () async {
      await web.write('refresh-token');

      expect(calls, isEmpty);
    });

    test('a read is not signed in', () async {
      // Not a lookup that happens to miss: the plugin is never called, so
      // there is nothing on the page for anything to find.
      expect(await web.read(), isNull);
      expect(calls, isEmpty);
    });

    test('clearing is not a failure', () async {
      await expectLater(web.clear(), completes);
      expect(calls, isEmpty);
    });
  });
}
