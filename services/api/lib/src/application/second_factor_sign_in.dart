import 'dart:convert';
import 'dart:math';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/second_factor.dart';
import 'ports/user_directory.dart';

/// Why a second factor could not be proven.
sealed class SecondFactorFailure extends DomainFailure {
  const SecondFactorFailure();
}

/// The half-session between "your emailed code was right" and "your
/// authenticator code was right" is gone: expired, tampered with, or never
/// issued. One failure for three causes, for the same reason
/// `ChallengeNoLongerValid` is one for four.
final class HalfSessionExpired extends SecondFactorFailure {
  const HalfSessionExpired();
  @override
  String get code => ErrorCode.mfaExpired;
}

final class FactorCodeIncorrect extends SecondFactorFailure {
  const FactorCodeIncorrect(this.attemptsRemaining);
  final int attemptsRemaining;
  @override
  String get code => ErrorCode.mfaIncorrect;
  @override
  Map<String, Object?> get params => {'remaining': attemptsRemaining};
}

/// Too many wrong codes. Carries the wait, because a lock with no stated end
/// is a support call rather than a control.
final class FactorLocked extends SecondFactorFailure {
  const FactorLocked(this.retryAfter);
  final Duration retryAfter;
  @override
  String get code => ErrorCode.mfaLocked;
  @override
  Map<String, Object?> get params => {'seconds': retryAfter.inSeconds};
}

/// Somebody with no confirmed factor tried to prove one.
final class NoFactorEnrolled extends SecondFactorFailure {
  const NoFactorEnrolled();
  @override
  String get code => ErrorCode.mfaEnrolmentRequired;
}

/// What a fresh enrolment hands back, exactly once.
final class Enrolment {
  const Enrolment({
    required this.secretBase32,
    required this.provisioningUri,
    required this.recoveryCodes,
  });

  final String secretBase32;
  final String provisioningUri;

  /// Shown once and never again — only their HMACs are stored. A list that
  /// can be re-read is a list an attacker with a live session can read too.
  final List<String> recoveryCodes;
}

/// The second factor, for the people who can move other people's money.
///
/// ADR-0013 asks for mandatory TOTP on both back-office surfaces. This is the
/// server half, and three decisions in it are worth stating plainly.
///
/// **Travellers are not asked.** A second factor on a traveller's account
/// would be a barrier in front of a coach ticket, and the thing it would
/// protect is one person's own bookings. [isRequiredFor] is what draws that
/// line, and it draws it from the *database* — operator staff or platform
/// staff — rather than from anything the client sends.
///
/// **Enrolment is not enforced by refusing to sign in.** Every existing staff
/// account would be locked out the hour this shipped, including the ones that
/// would have to fix it. Instead a staff member with no factor signs in and
/// the app puts them on the enrolment screen and nowhere else. That is the
/// honest reading of "mandatory" for a rollout, and it is stated here rather
/// than discovered.
///
/// **The half-session is a signed claim, not a row.** Between the emailed code
/// and the authenticator code there is a caller we have half-authenticated,
/// and giving them a bearer that a database has to remember buys nothing: it
/// is single-purpose, five minutes long, and useless without a code the
/// holder still has to compute. What it must not be is forgeable, which is
/// what the HMAC is for.
final class SecondFactorSignIn {
  SecondFactorSignIn({
    required SecondFactors factors,
    required MessageAuthenticator mac,
    required List<int> signingKey,
    Clock clock = const SystemClock(),
    Random? random,
    this.halfSessionTtl = const Duration(minutes: 5),
    this.lockAfter = 5,
    this.lockFor = const Duration(minutes: 15),
  }) : _factors = factors,
       _mac = mac,
       _key = signingKey,
       _clock = clock,
       // Random.secure() and nothing else: a TOTP seed from the default
       // generator is a seed somebody can reconstruct.
       _random = random ?? Random.secure();

  final SecondFactors _factors;
  final MessageAuthenticator _mac;
  final List<int> _key;
  final Clock _clock;
  final Random _random;

  final Duration halfSessionTtl;
  final int lockAfter;
  final Duration lockFor;

  /// Eight, which is the number people actually print and keep. Two would run
  /// out during one bad week; twenty would be a list nobody stores safely.
  static const recoveryCodeCount = 8;

  /// Who has to prove one.
  ///
  /// Read from the account the database resolved, never from a header. A
  /// client that decided whether it needed a second factor is a client an
  /// attacker can edit.
  bool isRequiredFor(Account account) =>
      account.staff != null || account.isPlatformStaff;

  /// What the sign-in route should do next for this account.
  Future<SecondFactorStep> stepFor(Account account) async {
    if (!isRequiredFor(account)) return const SecondFactorNotNeeded();

    final factor = await _factors.forUser(account.id);
    if (factor == null || !factor.isConfirmed) {
      // Signed in, but the app will show them one screen until they enrol.
      return const SecondFactorMustEnrol();
    }
    return SecondFactorProve(_mintHalfSession(account.id));
  }

  // ── Proving it ────────────────────────────────────────────────────────────

  /// Exchanges a half-session and a code for the right to a real session.
  ///
  /// Answers with the user id rather than a token: minting a Firebase custom
  /// token is the route's job, exactly as it is after a first-factor code, and
  /// this use case has no business knowing Firebase exists.
  Future<Result<String, SecondFactorFailure>> prove({
    required String halfSession,
    String? code,
    String? recoveryCode,
  }) async {
    final userId = _readHalfSession(halfSession);
    if (userId == null) return const Err(HalfSessionExpired());

    final factor = await _factors.forUser(userId);
    if (factor == null || !factor.isConfirmed) {
      return const Err(NoFactorEnrolled());
    }

    final now = _clock.now();
    if (factor.isLockedAt(now)) {
      return Err(FactorLocked(factor.lockedUntil!.difference(now)));
    }

    if (recoveryCode != null && recoveryCode.trim().isNotEmpty) {
      final spent = await _factors.spendRecoveryCode(
        userId: userId,
        codeHash: hashRecoveryCode(recoveryCode),
      );
      return spent ? Ok(userId) : _countFailure(userId);
    }

    final secret = Base32.decode(factor.secretBase32);
    if (secret == null) return const Err(NoFactorEnrolled());

    final window = Totp.windowOf(
      presented: code ?? '',
      secret: secret,
      now: now,
      mac: _mac,
    );
    if (window == null) return _countFailure(userId);

    // Spent, not merely matched. A code is valid for thirty seconds, which is
    // thirty seconds in which somebody who read it over a shoulder could use
    // it too — and the conditional UPDATE behind this is what makes a code
    // single-use even when two requests arrive together.
    final spent = await _factors.spendWindow(userId: userId, window: window);
    return spent ? Ok(userId) : _countFailure(userId);
  }

  Future<Result<String, SecondFactorFailure>> _countFailure(
    String userId,
  ) async {
    final after = await _factors.recordFailure(
      userId: userId,
      lockAfter: lockAfter,
      lockFor: lockFor,
    );
    final now = _clock.now();

    if (after != null && after.isLockedAt(now)) {
      return Err(FactorLocked(after.lockedUntil!.difference(now)));
    }
    return Err(
      FactorCodeIncorrect(
        after == null ? lockAfter - 1 : lockAfter - after.failedAttempts,
      ),
    );
  }

  // ── Enrolling ─────────────────────────────────────────────────────────────

  /// Starts enrolment, or restarts an abandoned one.
  ///
  /// Returns null when a **confirmed** factor already exists: replacing one is
  /// its own act, and doing it silently here would turn a stray click into a
  /// lockout of the person whose phone still holds the old secret.
  Future<Enrolment?> beginEnrolment(Account account) async {
    final secret = List<int>.generate(
      Totp.secretBytes,
      (_) => _random.nextInt(256),
    );
    final encoded = Base32.encode(secret);
    final codes = [for (var i = 0; i < recoveryCodeCount; i++) _recoveryCode()];

    final stored = await _factors.beginEnrolment(
      userId: account.id,
      secretBase32: encoded,
      recoveryHashes: [for (final code in codes) hashRecoveryCode(code)],
    );
    if (stored == null) return null;

    return Enrolment(
      secretBase32: encoded,
      provisioningUri: Totp.provisioningUri(
        secretBase32: encoded,
        account: account.email ?? account.phone ?? account.id,
      ),
      recoveryCodes: codes,
    );
  }

  /// Confirms enrolment by proving the app can compute a code.
  ///
  /// Nothing is treated as a second factor until this succeeds — an
  /// unconfirmed row would lock somebody out with a secret they mistyped.
  Future<bool> confirmEnrolment({
    required String userId,
    required String code,
  }) async {
    final factor = await _factors.forUser(userId);
    if (factor == null || factor.isConfirmed) return false;

    final secret = Base32.decode(factor.secretBase32);
    if (secret == null) return false;

    final window = Totp.windowOf(
      presented: code,
      secret: secret,
      now: _clock.now(),
      mac: _mac,
    );
    if (window == null) return false;

    return _factors.confirm(userId: userId, window: window);
  }

  Future<SecondFactor?> statusFor(String userId) => _factors.forUser(userId);

  /// Removes the factor. The burned recovery codes stay behind — one that was
  /// spent is evidence of the incident it was spent during.
  Future<void> disable(String userId) => _factors.disable(userId);

  // ── The half-session ──────────────────────────────────────────────────────

  String _mintHalfSession(String userId) {
    final expires = _clock.now().add(halfSessionTtl).millisecondsSinceEpoch;
    final payload = base64Url.encode(utf8.encode('$userId|$expires'));
    return '$payload.${_sign(payload)}';
  }

  /// Null for expired, tampered, malformed or absent. Constant-time on the
  /// signature, because a timing oracle here would let somebody forge one.
  String? _readHalfSession(String token) {
    final parts = token.split('.');
    if (parts.length != 2) return null;
    if (!_constantTimeEquals(_sign(parts[0]), parts[1])) return null;

    final String decoded;
    try {
      decoded = utf8.decode(base64Url.decode(parts[0]));
    } on FormatException {
      return null;
    }

    final fields = decoded.split('|');
    if (fields.length != 2) return null;

    final expires = int.tryParse(fields[1]);
    if (expires == null) return null;
    if (_clock.now().millisecondsSinceEpoch > expires) return null;

    return fields[0];
  }

  String _sign(String payload) => base64Url.encode(
    _mac.hmacSha256(key: _key, message: utf8.encode(payload)),
  );

  /// Ten characters from an alphabet with no `0`/`O` or `1`/`I`, because these
  /// get written on paper and read back over a phone line.
  String _recoveryCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final out = StringBuffer();
    for (var i = 0; i < 10; i++) {
      if (i == 5) out.write('-');
      out.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return out.toString();
  }

  /// Stored as an HMAC, never as itself — the same rule the emailed code
  /// follows. Case and dashes are normalised away first, because these are
  /// typed by a human reading their own handwriting.
  String hashRecoveryCode(String code) => base64Url.encode(
    _mac.hmacSha256(
      key: _key,
      message: utf8.encode(
        code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''),
      ),
    ),
  );

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

/// What the sign-in route should do once the emailed code was right.
sealed class SecondFactorStep {
  const SecondFactorStep();
}

/// A traveller. Issue the session.
final class SecondFactorNotNeeded extends SecondFactorStep {
  const SecondFactorNotNeeded();
}

/// Staff with nothing enrolled. Issue the session, and tell the app it must
/// put this person on the enrolment screen and nowhere else.
final class SecondFactorMustEnrol extends SecondFactorStep {
  const SecondFactorMustEnrol();
}

/// Staff with a confirmed factor. Issue **no** session, only the half-session
/// that a correct authenticator code will exchange.
final class SecondFactorProve extends SecondFactorStep {
  const SecondFactorProve(this.halfSession);
  final String halfSession;
}
