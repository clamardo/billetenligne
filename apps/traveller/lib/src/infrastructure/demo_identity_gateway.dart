import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';

import '../application/ports/identity_gateway.dart';

/// Signing in, with no server and no Firebase.
///
/// The twin of [DemoTravelGateway]: `flutter run` on a fresh clone reaches a
/// held seat, which is what makes the screens reviewable by somebody who is
/// not set up to run Postgres and an emulator.
///
/// It is a *faithful* twin in the ways that decide behaviour — the code is
/// wrong until it is right, the cooldown refuses a second ask, a used code is
/// refused — because a demo that accepts anything hides exactly the states the
/// screen exists to render.
final class DemoIdentityGateway implements IdentityGateway {
  DemoIdentityGateway({
    DateTime Function()? now,
    this.code = '424242',
    AccountDto? signedInAs,
  }) : _now = now ?? (() => DateTime.now().toUtc()),
       _account = signedInAs;

  final DateTime Function() _now;

  /// Fixed and printed on the screen's own hint in debug builds. There is no
  /// inbox to check here, so a random code would make the demo unusable.
  final String code;

  Duration latency = const Duration(milliseconds: 350);

  /// Starts signed in. For the widget tests whose subject is a screen *after*
  /// the gate, and for demoing those screens without typing a code first.
  AccountDto? _account;

  final _issued = <String, String>{};
  final _spent = <String>{};
  DateTime? _lastIssuedAt;
  var _counter = 0;

  @override
  AccountDto? get account => _account;

  @override
  bool get isSignedIn => _account != null;

  /// Nothing is persisted by the demo, deliberately: every launch starts
  /// signed out, so the sign-in screen is on the path rather than skipped
  /// after the first run.
  @override
  Future<bool> restore() async => false;

  @override
  Future<SignInChallengeDto> requestCode(String email) async {
    await Future<void>.delayed(latency);

    final normalised = email.trim().toLowerCase();
    if (!normalised.contains('@') ||
        !normalised.split('@').last.contains('.')) {
      throw const ServerRefused(400, ApiError(code: ErrorCode.emailInvalid));
    }

    final last = _lastIssuedAt;
    if (last != null && _now().difference(last) < const Duration(seconds: 60)) {
      final wait = 60 - _now().difference(last).inSeconds;
      throw ServerRefused(
        429,
        ApiError(code: ErrorCode.otpResendTooSoon, params: {'seconds': wait}),
      );
    }

    final id = 'demo-challenge-${++_counter}';
    _issued[id] = normalised;
    _lastIssuedAt = _now();

    return SignInChallengeDto(
      challengeId: id,
      channel: SignInChannel.email,
      sentTo: _mask(normalised),
      expiresAt: _now().add(const Duration(minutes: 5)),
      resendAfter: const Duration(seconds: 60),
      attemptsRemaining: 5,
    );
  }

  @override
  Future<AccountDto> submitCode({
    required String challengeId,
    required String code,
  }) async {
    await Future<void>.delayed(latency);

    final email = _issued[challengeId];
    if (email == null || _spent.contains(challengeId)) {
      throw const ServerRefused(401, ApiError(code: ErrorCode.otpExpired));
    }

    if (code.trim() != this.code) {
      throw const ServerRefused(
        401,
        ApiError(code: ErrorCode.otpIncorrect, params: {'remaining': 4}),
      );
    }

    _spent.add(challengeId);
    _account = AccountDto(id: 'u-demo', language: 'fr', email: email);
    return _account!;
  }

  @override
  Future<void> signOut() async => _account = null;

  static String _mask(String email) {
    final at = email.indexOf('@');
    final local = email.substring(0, at);
    final domain = email.substring(at + 1);
    if (local.length <= 2) return '${local[0]}***@$domain';
    return '${local[0]}***${local[local.length - 1]}@$domain';
  }
}
