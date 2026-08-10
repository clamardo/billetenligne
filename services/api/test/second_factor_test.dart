import 'dart:math';

import 'package:bel_api/src/application/ports/second_factor.dart';
import 'package:bel_api/src/application/ports/user_directory.dart';
import 'package:bel_api/src/application/second_factor_sign_in.dart';
import 'package:bel_api/src/infrastructure/memory/memory_second_factors.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

final class TestClock implements Clock {
  TestClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration by) => _now = _now.add(by);
}

/// A deterministic generator, so a test can assert on a secret rather than on
/// the fact that one exists.
final class SequenceRandom implements Random {
  SequenceRandom();
  var _next = 0;
  @override
  int nextInt(int max) => (_next++) % max;
  @override
  bool nextBool() => nextInt(2) == 0;
  @override
  double nextDouble() => nextInt(1000) / 1000;
}

const traveller = Account(id: 'u-traveller', language: 'fr');

const vendor = Account(
  id: 'u-vendor',
  language: 'fr',
  email: 'vendeur@ocean.cg',
  staff: StaffMembership(operatorId: 'op-1', roles: ['vendor']),
);

const admin = Account(
  id: 'u-admin',
  language: 'fr',
  email: 'ops@billetenligne.cg',
  platformRole: 'operations',
);

void main() {
  late TestClock clock;
  late MemorySecondFactors factors;
  late SecondFactorSignIn mfa;

  const mac = HmacSha256Authenticator();
  final key = List<int>.generate(32, (i) => i);

  /// What the authenticator app on somebody's phone would show right now.
  String codeFor(SecondFactor factor, DateTime at) => Totp.compute(
    secret: Base32.decode(factor.secretBase32)!,
    counter: Totp.windowAt(at),
    mac: mac,
  );

  /// Signs somebody all the way in: enrol, confirm, and hand back their
  /// half-session.
  Future<String> enrolAndChallenge(Account account) async {
    await mfa.beginEnrolment(account);
    final factor = (await factors.forUser(account.id))!;
    await mfa.confirmEnrolment(
      userId: account.id,
      code: codeFor(factor, clock.now()),
    );
    // Past the window the confirmation just spent. Confirming burns its code
    // like any other, which is what stops the code somebody typed into the
    // enrolment screen from also being a login — the cost is that enrolling
    // and signing in within the same thirty seconds needs the next tick.
    clock.advance(const Duration(seconds: 30));

    final step = await mfa.stepFor(account);
    return (step as SecondFactorProve).halfSession;
  }

  setUp(() {
    clock = TestClock(DateTime.utc(2026, 8, 10, 9));
    factors = MemorySecondFactors(now: clock.now);
    mfa = SecondFactorSignIn(
      factors: factors,
      mac: mac,
      signingKey: key,
      clock: clock,
      random: SequenceRandom(),
    );
  });

  group('who is asked for a second factor', () {
    test('a traveller is not', () async {
      expect(mfa.isRequiredFor(traveller), isFalse);
      expect(await mfa.stepFor(traveller), isA<SecondFactorNotNeeded>());
    });

    test('operator staff and platform staff are', () {
      expect(mfa.isRequiredFor(vendor), isTrue);
      expect(mfa.isRequiredFor(admin), isTrue);
    });

    // The rollout decision, asserted rather than described: staff with nothing
    // enrolled still get a session. Refusing one would have locked out every
    // existing staff account the hour this shipped.
    test(
      'staff with nothing enrolled sign in, and are told to enrol',
      () async {
        expect(await mfa.stepFor(vendor), isA<SecondFactorMustEnrol>());
      },
    );

    test('an unconfirmed enrolment is not a second factor', () async {
      await mfa.beginEnrolment(vendor);
      expect(await mfa.stepFor(vendor), isA<SecondFactorMustEnrol>());
    });

    test('a confirmed factor withholds the session', () async {
      await enrolAndChallenge(vendor);
      expect(await mfa.stepFor(vendor), isA<SecondFactorProve>());
    });
  });

  group('enrolment', () {
    test('hands back a scannable secret and eight recovery codes', () async {
      final enrolment = (await mfa.beginEnrolment(vendor))!;

      expect(
        Base32.decode(enrolment.secretBase32),
        hasLength(Totp.secretBytes),
      );
      expect(enrolment.recoveryCodes, hasLength(8));
      expect(enrolment.recoveryCodes.toSet(), hasLength(8));
      expect(
        enrolment.provisioningUri,
        startsWith('otpauth://totp/BilletEnLigne%3Avendeur%40ocean.cg'),
      );
    });

    test('a wrong code does not confirm it', () async {
      await mfa.beginEnrolment(vendor);
      expect(
        await mfa.confirmEnrolment(userId: vendor.id, code: '000000'),
        isFalse,
      );
      expect((await factors.forUser(vendor.id))!.isConfirmed, isFalse);
    });

    test('an abandoned enrolment can be restarted', () async {
      final first = (await mfa.beginEnrolment(vendor))!;
      final second = (await mfa.beginEnrolment(vendor))!;
      expect(second.secretBase32, isNot(first.secretBase32));
    });

    // Overwriting a working factor would turn a stray click into a lockout of
    // whoever's phone still holds the old secret.
    test('a confirmed factor is never silently replaced', () async {
      await enrolAndChallenge(vendor);
      expect(await mfa.beginEnrolment(vendor), isNull);
    });
  });

  group('proving it', () {
    test('the right code exchanges the half-session for a user', () async {
      final half = await enrolAndChallenge(vendor);
      final factor = (await factors.forUser(vendor.id))!;

      final result = await mfa.prove(
        halfSession: half,
        code: codeFor(factor, clock.now()),
      );
      expect((result as Ok<String, SecondFactorFailure>).value, vendor.id);
    });

    // Thirty seconds is thirty seconds in which somebody who read the code
    // over a shoulder could use it too.
    test('the same code cannot be spent twice', () async {
      final half = await enrolAndChallenge(vendor);
      final factor = (await factors.forUser(vendor.id))!;
      final code = codeFor(factor, clock.now());

      await mfa.prove(halfSession: half, code: code);
      final replay = await mfa.prove(halfSession: half, code: code);

      expect(replay, isA<Err<String, SecondFactorFailure>>());
      expect((replay as Err).failure, isA<FactorCodeIncorrect>());
    });

    test('a wrong code counts down, then locks the factor', () async {
      final half = await enrolAndChallenge(vendor);

      for (var attempt = 1; attempt < 5; attempt++) {
        final result = await mfa.prove(halfSession: half, code: '000000');
        final failure = (result as Err).failure as FactorCodeIncorrect;
        expect(failure.attemptsRemaining, 5 - attempt);
      }

      final fifth = await mfa.prove(halfSession: half, code: '000000');
      final locked = (fifth as Err).failure;
      expect(locked, isA<FactorLocked>());
      expect((locked as FactorLocked).retryAfter.inMinutes, 15);
    });

    // The lock is on the factor, not on the token: otherwise discarding a
    // half-session and asking for another would reset the guess budget.
    test('a fresh half-session does not reset the lock', () async {
      final half = await enrolAndChallenge(vendor);
      for (var i = 0; i < 5; i++) {
        await mfa.prove(halfSession: half, code: '000000');
      }

      final again = (await mfa.stepFor(vendor)) as SecondFactorProve;
      final factor = (await factors.forUser(vendor.id))!;
      final result = await mfa.prove(
        halfSession: again.halfSession,
        code: codeFor(factor, clock.now()),
      );

      expect((result as Err).failure, isA<FactorLocked>());
    });

    test('the lock lifts on its own', () async {
      final half = await enrolAndChallenge(vendor);
      for (var i = 0; i < 5; i++) {
        await mfa.prove(halfSession: half, code: '000000');
      }

      clock.advance(const Duration(minutes: 16));

      // A fresh half-session, because the old one is five minutes old and the
      // lock outlasted it by ten. Somebody who waits out a lock signs in from
      // the beginning, which is the flow they would actually follow.
      final again = (await mfa.stepFor(vendor)) as SecondFactorProve;
      final factor = (await factors.forUser(vendor.id))!;
      final result = await mfa.prove(
        halfSession: again.halfSession,
        code: codeFor(factor, clock.now()),
      );

      expect(result, isA<Ok<String, SecondFactorFailure>>());
    });
  });

  group('recovery codes', () {
    test('one signs you in, and is spent', () async {
      final enrolment = (await mfa.beginEnrolment(vendor))!;
      final factor = (await factors.forUser(vendor.id))!;
      await mfa.confirmEnrolment(
        userId: vendor.id,
        code: codeFor(factor, clock.now()),
      );
      final half =
          ((await mfa.stepFor(vendor)) as SecondFactorProve).halfSession;
      final code = enrolment.recoveryCodes.first;

      expect(
        await mfa.prove(halfSession: half, recoveryCode: code),
        isA<Ok<String, SecondFactorFailure>>(),
      );
      expect((await factors.forUser(vendor.id))!.unusedRecoveryCodes, 7);

      final reuse = await mfa.prove(halfSession: half, recoveryCode: code);
      expect((reuse as Err).failure, isA<FactorCodeIncorrect>());
    });

    // These are read off paper, over a phone line, by somebody in a hurry.
    test('case and dashes do not matter', () async {
      final enrolment = (await mfa.beginEnrolment(vendor))!;
      final factor = (await factors.forUser(vendor.id))!;
      await mfa.confirmEnrolment(
        userId: vendor.id,
        code: codeFor(factor, clock.now()),
      );
      final half =
          ((await mfa.stepFor(vendor)) as SecondFactorProve).halfSession;

      final typed = enrolment.recoveryCodes.first.toLowerCase().replaceAll(
        '-',
        ' ',
      );
      expect(
        await mfa.prove(halfSession: half, recoveryCode: typed),
        isA<Ok<String, SecondFactorFailure>>(),
      );
    });

    test('they avoid the characters people misread', () async {
      final enrolment = (await mfa.beginEnrolment(vendor))!;
      for (final code in enrolment.recoveryCodes) {
        expect(code, matches(RegExp(r'^[A-HJ-NP-Z2-9]{5}-[A-HJ-NP-Z2-9]{5}$')));
      }
    });
  });

  group('the half-session', () {
    test('expires after five minutes', () async {
      final half = await enrolAndChallenge(vendor);
      clock.advance(const Duration(minutes: 6));

      final factor = (await factors.forUser(vendor.id))!;
      final result = await mfa.prove(
        halfSession: half,
        code: codeFor(factor, clock.now()),
      );
      expect((result as Err).failure, isA<HalfSessionExpired>());
    });

    // Without the signature this is a claim about who you are, typed by you.
    test('a tampered one names nobody', () async {
      final half = await enrolAndChallenge(vendor);
      final forged = '${half.split('.').first}.notasignature';

      final result = await mfa.prove(halfSession: forged, code: '000000');
      expect((result as Err).failure, isA<HalfSessionExpired>());
    });

    test('a malformed one is refused rather than throwing', () async {
      for (final bad in ['', 'nodot', 'a.b.c', '!!!.!!!']) {
        final result = await mfa.prove(halfSession: bad, code: '000000');
        expect((result as Err).failure, isA<HalfSessionExpired>());
      }
    });

    test('one account cannot re-sign another account into a session', () async {
      await enrolAndChallenge(vendor);
      final adminHalf = await enrolAndChallenge(admin);

      // The admin's own half-session works for the admin, and names only the
      // admin — there is no field a caller could edit to say "vendor".
      final factor = (await factors.forUser(admin.id))!;
      final result = await mfa.prove(
        halfSession: adminHalf,
        code: codeFor(factor, clock.now()),
      );
      expect((result as Ok<String, SecondFactorFailure>).value, admin.id);
    });
  });

  test('disabling removes the factor and the obligation to hold one', () async {
    await enrolAndChallenge(vendor);
    await mfa.disable(vendor.id);

    expect(await factors.forUser(vendor.id), isNull);
    expect(await mfa.stepFor(vendor), isA<SecondFactorMustEnrol>());
  });
}
