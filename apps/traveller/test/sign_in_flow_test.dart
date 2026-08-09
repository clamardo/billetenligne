import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_traveller/src/application/ports/identity_gateway.dart';
import 'package:bel_traveller/src/application/sign_in_flow.dart';
import 'package:flutter_test/flutter_test.dart';

/// A gateway the test drives directly. The demo gateway is exercised by the
/// widget tests; this one exists so a refusal can be produced on demand.
final class _ScriptedIdentity implements IdentityGateway {
  ApiFailure? requestFailure;
  ApiFailure? submitFailure;

  final List<String> requested = [];
  final List<String> submitted = [];

  Duration cooldown = const Duration(seconds: 60);

  @override
  AccountDto? account;

  @override
  bool get isSignedIn => account != null;

  @override
  Future<bool> restore() async => false;

  @override
  Future<SignInChallengeDto> requestCode(String email) async {
    requested.add(email);
    if (requestFailure != null) throw requestFailure!;
    return SignInChallengeDto(
      challengeId: 'ch-${requested.length}',
      channel: SignInChannel.email,
      sentTo: 'a***e@example.cg',
      expiresAt: DateTime.utc(2026, 8, 9, 6, 5),
      resendAfter: cooldown,
      attemptsRemaining: 5,
    );
  }

  @override
  Future<AccountDto> submitCode({
    required String challengeId,
    required String code,
  }) async {
    submitted.add(code);
    if (submitFailure != null) throw submitFailure!;
    return account = const AccountDto(
      id: 'u-1',
      language: 'fr',
      email: 'aline@example.cg',
    );
  }

  @override
  Future<void> signOut() async => account = null;
}

final class _MovableClock implements Clock {
  _MovableClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  late _ScriptedIdentity gateway;
  late _MovableClock clock;
  late SignInFlow flow;

  setUp(() {
    gateway = _ScriptedIdentity();
    clock = _MovableClock(DateTime.utc(2026, 8, 9, 6));
    flow = SignInFlow(gateway: gateway, clock: clock);
  });

  group('asking for a code', () {
    test('reaches the code screen', () async {
      await flow.requestCode('aline@example.cg');

      final step = flow.step as AwaitingCode;
      expect(step.challenge.sentTo, 'a***e@example.cg');
      expect(gateway.requested, ['aline@example.cg']);
    });

    test('trims what was typed', () async {
      await flow.requestCode('  aline@example.cg  ');
      expect(gateway.requested, ['aline@example.cg']);
    });

    test('an empty address does nothing at all', () async {
      await flow.requestCode('   ');
      expect(flow.step, isA<NeedsAddress>());
      expect(gateway.requested, isEmpty);
    });

    test('a refusal keeps the address in the field', () async {
      gateway.requestFailure = const ServerRefused(
        400,
        ApiError(code: ErrorCode.emailInvalid),
      );

      await flow.requestCode('aline@example');

      final step = flow.step as NeedsAddress;
      // Retyping an email on a phone keyboard because the server said no is
      // how somebody abandons a purchase.
      expect(step.address, 'aline@example');
      expect(step.failure, isA<ServerRefused>());
    });
  });

  group('the resend cooldown', () {
    test('comes from the server, not from a timer we invented', () async {
      gateway.cooldown = const Duration(seconds: 45);
      await flow.requestCode('aline@example.cg');

      expect(flow.resendWaitAt(clock.now()), const Duration(seconds: 45));

      clock.advance(const Duration(seconds: 30));
      expect(flow.resendWaitAt(clock.now()), const Duration(seconds: 15));

      clock.advance(const Duration(seconds: 20));
      expect(flow.resendWaitAt(clock.now()), Duration.zero);
    });

    test('resends to the real address, not the masked one', () async {
      await flow.requestCode('aline@example.cg');
      clock.advance(const Duration(minutes: 1));
      await flow.resend();

      // `challenge.sentTo` is `a***e@example.cg`. Resending from what is on
      // screen would post a literal string of asterisks and look, from the
      // traveller's side, exactly like a delivery failure.
      expect(gateway.requested, ['aline@example.cg', 'aline@example.cg']);
    });

    test('a refused resend keeps the traveller on the code screen', () async {
      await flow.requestCode('aline@example.cg');
      gateway.requestFailure = const ServerRefused(
        429,
        ApiError(code: ErrorCode.otpResendTooSoon, params: {'seconds': 40}),
      );

      await flow.resend();

      // The code they already have is still good. Sending them back to the
      // address field would strongly suggest otherwise.
      final step = flow.step as AwaitingCode;
      expect(step.failure, isA<ServerRefused>());
      expect(step.challenge.challengeId, 'ch-1');
    });

    test('resending before anything was sent does nothing', () async {
      await flow.resend();
      expect(gateway.requested, isEmpty);
    });
  });

  group('answering the code', () {
    test('a correct code signs in', () async {
      await flow.requestCode('aline@example.cg');
      await flow.submitCode('424242');

      final step = flow.step as SignedIn;
      expect(step.account.email, 'aline@example.cg');
      expect(gateway.isSignedIn, isTrue);
    });

    test('anything other than six digits is not even sent', () async {
      await flow.requestCode('aline@example.cg');
      await flow.submitCode('4242');

      // A round trip that can only be refused costs a traveller on 2G eight
      // seconds and a slice of a prepaid bundle.
      expect(gateway.submitted, isEmpty);
      expect(flow.step, isA<AwaitingCode>());
    });

    test('a wrong code stays on the screen and says what is left', () async {
      await flow.requestCode('aline@example.cg');
      gateway.submitFailure = const ServerRefused(
        401,
        ApiError(code: ErrorCode.otpIncorrect, params: {'remaining': 3}),
      );

      await flow.submitCode('000000');

      final step = flow.step as AwaitingCode;
      expect(step.failure, isA<ServerRefused>());
      // "Incorrect" and "incorrect, and two more wrong answers end this" are
      // different sentences.
      expect(step.attemptsRemaining, 3);
    });

    test('an expired challenge is still answered on the same screen', () async {
      await flow.requestCode('aline@example.cg');
      gateway.submitFailure = const ServerRefused(
        401,
        ApiError(code: ErrorCode.otpExpired),
      );

      await flow.submitCode('424242');

      // Resending is right there. Bouncing to the address field is not.
      expect(flow.step, isA<AwaitingCode>());
    });
  });

  group('changing address', () {
    test('goes back with the address prefilled', () async {
      await flow.requestCode('aline@example.cg');
      flow.changeAddress();

      final step = flow.step as NeedsAddress;
      expect(step.address, 'aline@example.cg');
      expect(flow.resendWaitAt(clock.now()), Duration.zero);
    });

    test('reset forgets everything', () async {
      await flow.requestCode('aline@example.cg');
      flow.reset();

      expect((flow.step as NeedsAddress).address, isNull);
      await flow.resend();
      expect(gateway.requested, hasLength(1));
    });
  });
}
