import 'dart:io';

import 'package:test/test.dart';

/// The launch spends the refresh token the Keystore kept.
///
/// A blunt assertion over a source file, and chosen deliberately. What broke
/// was not a unit of logic — `BelSession.restore` has its own tests and they
/// pass — it was a **wiring** omission: `main` built a `BelSession` over
/// `SecureSessionStore`, wrote a refresh token into it on every sign-in, and
/// never read it back. Nothing that constructs a widget can see that, because
/// the omission is in the one function no widget test calls.
///
/// The consequence was found by walking the app, not by running it: a
/// conductor whose handset killed the app had to sign in again with a code
/// **by e-mail** and an authenticator, on a coach, in a place ADR-0022 exists
/// because it has no signal. The traveller, console and back office all call
/// `restore()`; this app is the one where not calling it is not survivable.
///
/// So the guard is against the edit that would reintroduce it — somebody
/// tidying the launch path and deleting a line whose effect is invisible in
/// this file.
void main() {
  test('the scanner restores a stored session before the first screen', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(
      source,
      contains('session.restore()'),
      reason:
          'main() must spend the stored refresh token at launch, or the '
          'secure store is written and never read',
    );

    // And it has to happen before the tree exists, not from a screen: a
    // sign-in screen that flashes and replaces itself is a screen a conductor
    // starts typing into. `lastIndexOf`, because the first `runApp` in this
    // file is the demo gateway's early return, which has no session at all.
    expect(
      source.indexOf('session.restore()'),
      greaterThan(source.indexOf('BelSession(')),
      reason: 'the session has to exist before it can be restored',
    );
    expect(
      source.indexOf('session.restore()'),
      lessThan(source.lastIndexOf('runApp(')),
      reason: 'restore before runApp, so the first screen is the right one',
    );
  });
}
