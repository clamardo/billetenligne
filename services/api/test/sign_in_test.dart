import 'dart:convert';
import 'dart:math';

import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/application/sign_in.dart';
import 'package:bel_api/src/infrastructure/memory/memory_identity.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// A clock the test moves by hand. The cooldown, the TTL and the replay window
/// are all statements about time, and a test that cannot move time can only
/// assert the happy path.
final class TestClock implements Clock {
  TestClock(this._now);
  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration d) => _now = _now.add(d);
}

/// Deterministic codes, so a test can assert on the one that was sent without
/// reading it out of the fake gateway every time.
final class FixedRandom implements Random {
  FixedRandom(this.value);
  final int value;

  @override
  int nextInt(int max) => value % max;

  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

void main() {
  late TestClock clock;
  late MemoryAuthChallenges challenges;
  late MemoryUserDirectory directory;
  late FakeNotificationGateway notifications;
  late SignIn signIn;

  /// Renders something recognisable without loading a catalog from disk. The
  /// real renderer is exercised by the smoke suite, against the real YAML.
  ({String? subject, String body}) render({
    required SignInChannel channel,
    required String language,
    required String code,
    required int minutes,
  }) => (subject: 'code:$code', body: '$language/$code/$minutes');

  SignIn build({Random? random}) => SignIn(
    challenges: challenges,
    directory: directory,
    notifications: notifications,
    render: render,
    mac: const HmacSha256Authenticator(),
    codeKey: utf8.encode('a-test-key-of-at-least-32-characters'),
    clock: clock,
    random: random ?? FixedRandom(424242),
  );

  setUp(() {
    clock = TestClock(DateTime.utc(2026, 8, 9, 6));
    challenges = MemoryAuthChallenges(clock: clock);
    directory = MemoryUserDirectory(clock: clock);
    notifications = FakeNotificationGateway();
    signIn = build();
  });

  /// The code as the traveller received it, read off the message rather than
  /// off the challenge — because the challenge deliberately does not have it.
  String codeFromMessage() =>
      notifications.last.subject!.substring('code:'.length);

  group('starting a sign-in', () {
    test('sends a code and never returns it', () async {
      final result = await signIn.start(
        const StartSignInRequest.email('Aline@Example.CG'),
      );

      final challenge = result.valueOrNull!;
      expect(notifications.sent, hasLength(1));
      expect(challenge.channel, SignInChannel.email);
      expect(challenge.attemptsRemaining, 5);

      // Nothing in the response resembles the code. This is the field a debug
      // branch leaks, so it is asserted rather than assumed.
      expect(jsonEncode(challenge.toJson()), isNot(contains(codeFromMessage())));
    });

    test('masks the address it echoes back', () async {
      final result = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );

      // Enough to recognise which address you typed; not enough to read one
      // off a stolen, unlocked phone.
      expect(result.valueOrNull!.sentTo, 'a***e@example.cg');
    });

    test('normalises the address before it is sent or stored', () async {
      await signIn.start(const StartSignInRequest.email('  Aline@Example.CG '));
      expect(notifications.last.to, 'aline@example.cg');
    });

    test('refuses an address that cannot be one', () async {
      final result = await signIn.start(
        const StartSignInRequest.email('aline-at-example'),
      );

      expect(result.failureOrNull, isA<UnusableAddress>());
      expect(result.failureOrNull!.code, ErrorCode.emailInvalid);
      expect(notifications.sent, isEmpty);
    });

    test('a second request within the cooldown is refused with the wait', () async {
      await signIn.start(const StartSignInRequest.email('aline@example.cg'));
      clock.advance(const Duration(seconds: 20));

      final again = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );

      final failure = again.failureOrNull;
      expect(failure, isA<ResendTooSoon>());
      expect((failure! as ResendTooSoon).retryAfter, const Duration(seconds: 40));
      // The cooldown is a cost control as much as a security one: the message
      // that was not sent is the point (ADR-0019).
      expect(notifications.sent, hasLength(1));
    });

    test('the cooldown keys on the address, not on the challenge', () async {
      // Otherwise "ask again" with a fresh challenge id sidesteps it, which is
      // the shape this check usually has when it does nothing at all.
      await signIn.start(const StartSignInRequest.email('aline@example.cg'));
      clock.advance(const Duration(seconds: 5));

      final capitalised = await signIn.start(
        const StartSignInRequest.email('ALINE@EXAMPLE.CG'),
      );
      expect(capitalised.failureOrNull, isA<ResendTooSoon>());
    });

    test('a different address is not held up by another address cooldown', () async {
      await signIn.start(const StartSignInRequest.email('aline@example.cg'));
      final other = await signIn.start(
        const StartSignInRequest.email('serge@example.cg'),
      );
      expect(other.isOk, isTrue);
    });

    test('an unreachable rail is reported, and the challenge still exists', () async {
      notifications.failWith = NotifyFailure.railUnavailable;

      final result = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );

      expect((result.failureOrNull! as CouldNotDeliver).code,
          ErrorCode.unavailable);

      // Deleting the challenge would let a bounced address be retried
      // instantly, turning a delivery failure into a way around the cooldown.
      clock.advance(const Duration(seconds: 5));
      notifications.failWith = null;
      final retry = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );
      expect(retry.failureOrNull, isA<ResendTooSoon>());
    });

    test('the same answer for a stranger and a returning customer', () async {
      final first = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );
      await signIn.complete(
        VerifySignInRequest(
          challengeId: first.valueOrNull!.challengeId,
          code: codeFromMessage(),
        ),
      );

      clock.advance(const Duration(minutes: 5));

      final returning = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );
      final stranger = await signIn.start(
        const StartSignInRequest.email('nobody@example.cg'),
      );

      // Field for field identical apart from the id, the address and the
      // clock. An API that answered differently could be used to ask "is this
      // person a customer of yours?" one address at a time.
      final a = returning.valueOrNull!.toJson()..remove('challengeId')
        ..remove('sentTo');
      final b = stranger.valueOrNull!.toJson()..remove('challengeId')
        ..remove('sentTo');
      expect(a, b);
    });
  });

  group('completing a sign-in', () {
    Future<String> startAndGetId([String email = 'aline@example.cg']) async {
      final result = await signIn.start(StartSignInRequest.email(email));
      return result.valueOrNull!.challengeId;
    }

    test('a correct code creates the account exactly once', () async {
      final id = await startAndGetId();
      final first = await signIn.complete(
        VerifySignInRequest(challengeId: id, code: codeFromMessage()),
      );

      expect(first.valueOrNull!.isNewAccount, isTrue);
      expect(first.valueOrNull!.account.email, 'aline@example.cg');

      clock.advance(const Duration(minutes: 2));
      final second = await startAndGetId();
      final again = await signIn.complete(
        VerifySignInRequest(challengeId: second, code: codeFromMessage()),
      );

      expect(again.valueOrNull!.isNewAccount, isFalse);
      expect(again.valueOrNull!.account.id, first.valueOrNull!.account.id);
    });

    test('a wrong code spends an attempt and says how many are left', () async {
      final id = await startAndGetId();

      final wrong = await signIn.complete(
        const VerifySignInRequest(challengeId: 'x', code: '000000'),
      );
      expect(wrong.failureOrNull, isA<ChallengeNoLongerValid>());

      final result = await signIn.complete(
        VerifySignInRequest(challengeId: id, code: '000001'),
      );
      final failure = result.failureOrNull! as CodeIncorrect;
      expect(failure.attemptsRemaining, 4);
      expect(failure.params['remaining'], 4);
    });

    test('five wrong codes ends it, and the right code no longer works', () async {
      final id = await startAndGetId();
      final correct = codeFromMessage();

      for (var i = 0; i < 5; i++) {
        await signIn.complete(
          VerifySignInRequest(challengeId: id, code: '00000$i'),
        );
      }

      final result = await signIn.complete(
        VerifySignInRequest(challengeId: id, code: correct),
      );
      expect(result.failureOrNull, isA<TooManyAttempts>());
      expect(result.failureOrNull!.code, ErrorCode.otpTooManyAttempts);
    });

    test('an expired code is refused', () async {
      final id = await startAndGetId();
      final correct = codeFromMessage();

      clock.advance(const Duration(minutes: 5, seconds: 1));

      final result = await signIn.complete(
        VerifySignInRequest(challengeId: id, code: correct),
      );
      expect(result.failureOrNull, isA<ChallengeNoLongerValid>());
    });

    test('a correct code cannot be replayed', () async {
      final id = await startAndGetId();
      final correct = codeFromMessage();

      expect((await signIn.complete(
        VerifySignInRequest(challengeId: id, code: correct),
      )).isOk, isTrue);

      final replay = await signIn.complete(
        VerifySignInRequest(challengeId: id, code: correct),
      );
      expect(replay.failureOrNull, isA<ChallengeNoLongerValid>());
    });

    test('expired, spent and never-existed are one answer', () async {
      // Distinguishing them tells whoever holds a challenge id whether they
      // are grinding a live code or a dead one.
      final spentId = await startAndGetId();
      final correct = codeFromMessage();
      await signIn.complete(
        VerifySignInRequest(challengeId: spentId, code: correct),
      );

      clock.advance(const Duration(minutes: 2));
      final expiredId = await startAndGetId('serge@example.cg');
      clock.advance(const Duration(minutes: 6));

      final answers = <String>{};
      for (final id in [spentId, expiredId, '11111111-0000-0000-0000-000000000000']) {
        final result = await signIn.complete(
          VerifySignInRequest(challengeId: id, code: '123456'),
        );
        answers.add(result.failureOrNull!.code);
      }

      expect(answers, {ErrorCode.otpExpired});
    });
  });

  group('the code itself', () {
    test('keeps its leading zeros', () async {
      signIn = build(random: FixedRandom(42));
      await signIn.start(const StartSignInRequest.email('aline@example.cg'));

      // `nextInt(1000000)` and pad, not `nextInt(900000) + 100000` — which
      // silently discards a tenth of the keyspace to avoid this line.
      expect(codeFromMessage(), '000042');
      expect(codeFromMessage(), hasLength(6));
    });

    test('is stored as a keyed hash, never as itself', () async {
      final result = await signIn.start(
        const StartSignInRequest.email('aline@example.cg'),
      );
      final stored = await challenges.byId(result.valueOrNull!.challengeId);

      expect(stored!.codeHash, isNot(contains(codeFromMessage())));
      expect(stored.codeHash, hasLength(64));
      // Keyed: a different key over the same code is a different digest, which
      // is what stops a precomputed table over a million values.
      expect(stored.codeHash, signIn.hashOf(codeFromMessage()));
    });
  });

  test('the logging gateway is what a fresh clone gets', () async {
    // ADR-0019: blank is a supported state. A new engineer clones the repo,
    // signs in, and reads the code off the log rather than an inbox.
    const gateway = LoggingNotificationGateway();
    expect(
      await gateway.send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'aline@example.cg',
          body: 'code 424242',
        ),
      ),
      isNull,
    );
  });
}
