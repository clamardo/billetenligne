import 'dart:convert';
import 'dart:math';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/auth_challenges.dart';
import 'ports/notification_gateway.dart';
import 'ports/user_directory.dart';

/// Why a sign-in step could not proceed.
///
/// Note what is *absent*: there is no "no such account". Sign-up and sign-in
/// are one flow, so the API never has cause to say whether an address is
/// registered — and an API that will not say cannot be used to enumerate our
/// customers.
sealed class SignInFailure extends DomainFailure {
  const SignInFailure();
}

final class UnusableAddress extends SignInFailure {
  const UnusableAddress(this.failure);
  final DomainFailure failure;
  @override
  String get code => failure.code;
  @override
  Map<String, Object?> get params => failure.params;
}

/// Asked for another code before the cooldown elapsed.
///
/// Carries the wait, so the app can render a countdown rather than a shrug.
/// The cooldown is the cost control as much as the security control: every
/// resend is a message we pay for (ADR-0019).
final class ResendTooSoon extends SignInFailure {
  const ResendTooSoon(this.retryAfter);
  final Duration retryAfter;
  @override
  String get code => ErrorCode.otpResendTooSoon;
  @override
  Map<String, Object?> get params => {'seconds': retryAfter.inSeconds};
}

/// One host asked for too many codes in an hour.
///
/// Distinct from [ResendTooSoon] and it must be: that one is about an
/// *address* and is a normal thing to hit — you asked twice. This one is
/// about a *host*, and hitting it means either something is wrong or somebody
/// is doing something odd. Carries the wait for the same reason: a limit that
/// cannot say when it lifts is a limit people retry against blindly.
final class TooManyFromOneSource extends SignInFailure {
  const TooManyFromOneSource(this.retryAfter);
  final Duration retryAfter;
  @override
  String get code => ErrorCode.otpSourceRateLimited;
  @override
  Map<String, Object?> get params => {'seconds': retryAfter.inSeconds};
}

/// We could not reach them at all — the rail was down or the address bounced.
///
/// Distinct from every failure above it because it is *our* problem, and the
/// only honest thing to show is "try again" rather than "check your code".
final class CouldNotDeliver extends SignInFailure {
  const CouldNotDeliver(this.reason);
  final NotifyFailure reason;
  @override
  String get code => switch (reason) {
    NotifyFailure.invalidRecipient => ErrorCode.emailInvalid,
    _ => ErrorCode.unavailable,
  };
}

/// The code was wrong. Carries what is left, because "incorrect" and
/// "incorrect, and one more wrong answer ends this" are different sentences.
final class CodeIncorrect extends SignInFailure {
  const CodeIncorrect(this.attemptsRemaining);
  final int attemptsRemaining;
  @override
  String get code => ErrorCode.otpIncorrect;
  @override
  Map<String, Object?> get params => {'remaining': attemptsRemaining};
}

/// Expired, already used, exhausted, or never existed.
///
/// **One failure for four causes, on purpose.** Distinguishing them tells an
/// attacker holding a stolen challenge id whether they are grinding a live
/// code or a dead one, and tells a legitimate traveller nothing they can act
/// on that "ask for a new code" does not already cover.
final class ChallengeNoLongerValid extends SignInFailure {
  const ChallengeNoLongerValid();
  @override
  String get code => ErrorCode.otpExpired;
}

final class TooManyAttempts extends SignInFailure {
  const TooManyAttempts();
  @override
  String get code => ErrorCode.otpTooManyAttempts;
}

/// A correct code, and what it bought.
final class SignedIn {
  const SignedIn({required this.account, required this.isNewAccount});
  final Account account;
  final bool isNewAccount;
}

/// Renders the message body. Injected rather than imported so this use case
/// stays testable without a catalog on disk, and so the *server* remains the
/// only place prose is produced (ADR-0008).
typedef RenderMessage =
    ({String? subject, String body, String? heading, String? highlight})
    Function({
      required SignInChannel channel,
      required String language,
      required String code,
      required int minutes,
    });

/// Sign in with a one-time code, over a channel we own.
///
/// Firebase is still the identity provider (ADR-0018) — a correct code is
/// answered with a Firebase custom token by the caller, not with a session of
/// our own invention. What moves here is the *challenge*, and only the
/// challenge, which is the fallback ADR-0018 documents and ADR-0019 asks us to
/// build early enough to have the option.
///
/// Email leads because it is the channel that is configured today and because
/// an emailed code costs nothing per attempt. Phone is second and not absent:
/// everything below is channel-agnostic, so adding SMS is an adapter and a
/// template rather than a second flow with a second set of bugs.
///
/// Four properties hold regardless of channel:
///
///   * **The code is never stored.** An HMAC of it is. A dump of the challenge
///     table lets nobody sign in as anybody.
///   * **The response is the same for a stranger and a returning customer.**
///     Sign-up and sign-in are one operation, so there is nothing to leak.
///   * **A wrong answer is counted before the caller learns the verdict**, so
///     hanging up mid-response still spends the attempt.
///   * **Comparison is constant-time.** A comparison that returns early on the
///     first wrong digit turns a million-guess search into ten.
final class SignIn {
  SignIn({
    required AuthChallenges challenges,
    required UserDirectory directory,
    required NotificationGateway notifications,
    required RenderMessage render,
    required List<int> codeKey,
    required MessageAuthenticator mac,
    Clock clock = const SystemClock(),
    Random? random,
    this.codeTtl = const Duration(minutes: 5),
    this.resendCooldown = const Duration(seconds: 60),
    this.maxAttempts = 5,
    this.sourceWindow = const Duration(hours: 1),
    this.maxPerSource = 30,
    this.msisdn = MsisdnPrefixTable.congoBrazzaville,
  }) : _challenges = challenges,
       _directory = directory,
       _notifications = notifications,
       _render = render,
       _codeKey = codeKey,
       _mac = mac,
       _clock = clock,
       // Random.secure() and nothing else. A six-digit code from the default
       // generator is predictable from a handful of observations, and the
       // observations are free: anyone can ask for a code.
       _random = random ?? Random.secure();

  /// How a typed number becomes an MSISDN: dialling code, national length and
  /// the carrier prefixes. Injected rather than taken from the default,
  /// because the table is configuration (`config/markets.yaml`, ADR-0005) —
  /// a carrier that renumbers must not need a release before its subscribers
  /// can sign in.
  final MsisdnPrefixTable msisdn;

  final AuthChallenges _challenges;
  final UserDirectory _directory;
  final NotificationGateway _notifications;
  final RenderMessage _render;
  final List<int> _codeKey;
  final MessageAuthenticator _mac;
  final Clock _clock;
  final Random _random;

  /// Five minutes (ADR-0013). Long enough for an SMS to arrive on a bad
  /// network, short enough that a code read over someone's shoulder is worth
  /// little by the time it is used.
  final Duration codeTtl;

  final Duration resendCooldown;
  final int maxAttempts;

  /// How many codes one host may ask for, and over what period.
  ///
  /// **Deliberately loose.** In this market a very large share of traffic
  /// arrives from behind carrier-grade NAT and from cybercafés, so one
  /// address is routinely one *building* — an agency counter signing in six
  /// staff, or a family sharing a connection. A bound tight enough to stop a
  /// determined attacker would lock those people out, and locking out an
  /// agency to save a few hundred francs of SMS is the wrong trade.
  ///
  /// So this is a **cost control before it is a security control**: it stops
  /// the loop left running and the script pointed at us, which is most of
  /// what actually happens, and it does not pretend to stop somebody with a
  /// list of proxies. The per-destination cooldown and the five-attempt cap
  /// are what protect an individual account; this protects the bill.
  final Duration sourceWindow;
  final int maxPerSource;

  // ── Step one: send a code ─────────────────────────────────────────────────

  Future<Result<SignInChallengeDto, SignInFailure>> start(
    StartSignInRequest request, {
    String language = 'fr',
    String? source,
  }) async {
    final address = switch (request.channel) {
      SignInChannel.email => _normaliseEmail(request.email!),
      SignInChannel.phone => _normalisePhone(request.phone!),
    };

    return switch (address) {
      Err(:final failure) => Err(failure),
      Ok(value: (final destination, final masked, final channel)) =>
        await _issue(
          channel: channel,
          destination: destination,
          masked: masked,
          language: language,
          // Hashed here rather than by the caller, under the same key the
          // codes are hashed with: the port below never sees an address, so
          // `auth_challenges` cannot become a log of who asked from where.
          sourceHash: source == null || source.isEmpty
              ? null
              : hashOf('src:$source'),
        ),
    };
  }

  Future<Result<SignInChallengeDto, SignInFailure>> _issue({
    required SignInChannel channel,
    required String destination,
    required String masked,
    required String language,
    String? sourceHash,
  }) async {
    final now = _clock.now();

    // Checked before the per-address cooldown, and that order is the point:
    // the cooldown is keyed on the destination, so a host walking a list of a
    // thousand addresses never hits it once. This is the check that sees them.
    if (sourceHash != null) {
      final sent = await _challenges.issuedFrom(
        sourceHash,
        since: now.subtract(sourceWindow),
      );
      if (sent.count >= maxPerSource) {
        final freeAt = (sent.earliest ?? now).add(sourceWindow);
        final wait = freeAt.difference(now);
        return Err(
          TooManyFromOneSource(wait.isNegative ? Duration.zero : wait),
        );
      }
    }

    // Keyed on the destination, not on a challenge id: otherwise "ask again"
    // with a fresh id sidesteps the limit entirely, which is the shape this
    // check usually has when it does nothing.
    final lastSent = await _challenges.lastIssuedTo(destination);
    if (lastSent != null) {
      final elapsed = now.difference(lastSent);
      if (elapsed < resendCooldown) {
        return Err(ResendTooSoon(resendCooldown - elapsed));
      }
    }

    final code = _generateCode();

    final challenge = await _challenges.issue(
      channel: channel,
      destination: destination,
      codeHash: hashOf(code),
      language: language,
      expiresAt: now.add(codeTtl),
      maxAttempts: maxAttempts,
      sourceHash: sourceHash,
    );

    final message = _render(
      channel: channel,
      language: language,
      code: code,
      minutes: codeTtl.inMinutes,
    );

    final failure = await _notifications.send(
      OutboundMessage(
        channel: channel,
        to: destination,
        subject: message.subject,
        body: message.body,
        language: language,
        heading: message.heading,
        highlight: message.highlight,
      ),
    );

    // The challenge row stays even when the send failed. It costs nothing, it
    // expires on its own, and deleting it would let a bounced address be
    // retried instantly — turning a delivery failure into a way around the
    // cooldown.
    if (failure != null) return Err(CouldNotDeliver(failure));

    return Ok(
      SignInChallengeDto(
        challengeId: challenge.id,
        channel: channel,
        sentTo: masked,
        expiresAt: challenge.expiresAt,
        resendAfter: resendCooldown,
        attemptsRemaining: challenge.attemptsRemaining,
      ),
    );
  }

  // ── Step two: check it ────────────────────────────────────────────────────

  Future<Result<SignedIn, SignInFailure>> complete(
    VerifySignInRequest request,
  ) async {
    final challenge = await _challenges.byId(request.challengeId);
    final now = _clock.now();

    // Absent, spent, or stale — one answer. A challenge id is a bearer of
    // sorts, and telling its holder which of those it is tells them whether
    // to keep going.
    if (challenge == null ||
        challenge.isConsumed ||
        challenge.hasExpiredBy(now)) {
      return const Err(ChallengeNoLongerValid());
    }

    if (challenge.isExhausted) return const Err(TooManyAttempts());

    if (!_matches(request.code, challenge.codeHash)) {
      // Counted first. A client that disconnects while this response is in
      // flight has still spent the attempt, which is the difference between a
      // rate limit and a suggestion.
      final after = await _challenges.recordFailedAttempt(challenge.id);
      final remaining = after?.attemptsRemaining ?? 0;
      return remaining <= 0
          ? const Err(TooManyAttempts())
          : Err(CodeIncorrect(remaining));
    }

    final resolved = switch (challenge.channel) {
      SignInChannel.email => await _directory.forVerifiedEmail(
        email: challenge.destination,
        language: challenge.language,
      ),
      SignInChannel.phone => await _directory.forVerifiedPhone(
        phone: challenge.destination,
        language: challenge.language,
      ),
    };

    // Conditional in the database, not a read-then-write here: two requests
    // arriving with the same correct code must produce one sign-in, and only
    // the write can decide which of them it was.
    final burned = await _challenges.consume(
      id: challenge.id,
      userId: resolved.account.id,
    );
    if (!burned) return const Err(ChallengeNoLongerValid());

    return Ok(
      SignedIn(account: resolved.account, isNewAccount: resolved.created),
    );
  }

  // ── Codes ─────────────────────────────────────────────────────────────────

  /// Six digits, uniformly distributed, leading zeros retained.
  ///
  /// `nextInt(1000000)` and pad — not six independent digits, which is the
  /// same thing written less clearly, and not `nextInt(900000) + 100000`,
  /// which quietly removes a tenth of the keyspace to avoid the padding.
  String _generateCode() => _random.nextInt(1000000).toString().padLeft(6, '0');

  /// HMAC-SHA256 under a server-side key, hex encoded.
  ///
  /// A plain hash would not do: the space is a million values, so an unkeyed
  /// digest of every possible code is a table anyone can build in a second.
  /// The key is what makes a stolen database useless without also stealing
  /// the server's configuration.
  String hashOf(String code) => _mac
      .hmacSha256(key: _codeKey, message: utf8.encode(code))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  bool _matches(String candidate, String expected) =>
      _constantTimeEquals(hashOf(candidate.trim()), expected);

  /// Compares every character regardless of where the first difference is.
  ///
  /// Both sides are hex digests of the same length here, so the timing signal
  /// is small — but "small" is a property of today's code, and this function
  /// costs nothing.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ── Address handling ──────────────────────────────────────────────────────

  Result<(String, String, SignInChannel), SignInFailure> _normaliseEmail(
    String raw,
  ) => EmailAddress.parse(raw).fold(
    (email) => Ok((email.value, email.masked, SignInChannel.email)),
    (failure) => Err(UnusableAddress(failure)),
  );

  Result<(String, String, SignInChannel), SignInFailure> _normalisePhone(
    String raw,
  ) => PhoneNumber.parse(raw, table: msisdn).fold(
    (phone) => Ok((phone.e164, _maskPhone(phone), SignInChannel.phone)),
    (failure) => Err(UnusableAddress(failure)),
  );

  /// `+242 •• ••• •• 67` — the last two digits are what a traveller checks a
  /// number by, and the rest is what a shoulder-surfer would need.
  static String _maskPhone(PhoneNumber phone) {
    final national = phone.national;
    final tail = national.substring(national.length - 2);
    return '+${phone.table.countryCode} •• ••• •• $tail';
  }
}
