import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/identity_gateway.dart';

/// Where the traveller is in signing in.
sealed class SignInStep {
  const SignInStep();
}

/// Asking for the address. The first thing shown, and the only screen in the
/// whole funnel that appears before a traveller has seen a price.
final class NeedsAddress extends SignInStep {
  const NeedsAddress({this.failure, this.address});

  /// A previous attempt's refusal, rendered above the field: an invalid
  /// address, or a cooldown they hit.
  final ApiFailure? failure;

  /// What they typed, kept so a refusal does not clear the field.
  final String? address;
}

final class SendingCode extends SignInStep {
  const SendingCode(this.address);
  final String address;
}

/// The code is out. [challenge] carries the masked address, the expiry and the
/// cooldown — all server-decided, so the screen's countdown and the server's
/// limit cannot drift apart.
final class AwaitingCode extends SignInStep {
  const AwaitingCode(this.challenge, {this.failure, this.resending = false});

  final SignInChallengeDto challenge;

  /// A wrong code, an expired one, or a resend refused. Never a reason to
  /// leave the screen — every one of these is answered by typing again or
  /// waiting.
  final ApiFailure? failure;

  final bool resending;

  /// What the server said is left. A wrong code carries this in its params,
  /// and it is the difference between "incorrect" and "incorrect, and one more
  /// wrong answer ends this".
  int? get attemptsRemaining => switch (failure) {
    ServerRefused(:final params) when params['remaining'] is int =>
      params['remaining']! as int,
    _ => null,
  };
}

final class VerifyingCode extends SignInStep {
  const VerifyingCode(this.challenge);
  final SignInChallengeDto challenge;
}

final class SignedIn extends SignInStep {
  const SignedIn(this.account, {required this.isNew});
  final AccountDto account;
  final bool isNew;
}

/// Becoming a customer.
///
/// A separate flow from `BookingFlow`, and a plain broadcast stream for the
/// same reason: `ChangeNotifier` lives in `package:flutter/foundation` and the
/// layer check refuses Flutter here.
///
/// Three things it is careful about, each of which costs a traveller a real
/// booking when it is got wrong:
///
///   * **A wrong code never leaves the screen.** Incorrect, expired,
///     exhausted — all are answered by typing again or asking for another,
///     and bouncing back to the address field would lose the code that is
///     sitting in their inbox.
///   * **The resend cooldown comes from the server.** The screen renders a
///     countdown from what the server said, so the button and the limit agree.
///     A client-side timer is a suggestion the server has never heard of.
///   * **The address survives a refusal.** Retyping an email on a phone
///     keyboard because the server said "wait 40 seconds" is how somebody
///     abandons a purchase.
final class SignInFlow {
  SignInFlow({required IdentityGateway gateway, Clock clock = const SystemClock()})
    : _gateway = gateway,
      _clock = clock;

  final IdentityGateway _gateway;
  final Clock _clock;

  final _steps = StreamController<SignInStep>.broadcast();

  SignInStep _step = const NeedsAddress();
  SignInStep get step => _step;
  Stream<SignInStep> get steps => _steps.stream;

  /// When "send it again" starts working. Derived from the server's cooldown
  /// at the moment the code was issued.
  DateTime? _resendAvailableAt;
  DateTime? get resendAvailableAt => _resendAvailableAt;

  /// The address a code was actually sent to.
  ///
  /// Kept here because the challenge only carries the **masked** form —
  /// `a***e@example.cg`, which is right for the screen and useless as an
  /// argument. Resending from what is on screen would send a code to a
  /// literal address full of asterisks.
  String? _address;

  Duration resendWaitAt(DateTime now) {
    final at = _resendAvailableAt;
    if (at == null || !now.isBefore(at)) return Duration.zero;
    return at.difference(now);
  }

  void _emit(SignInStep next) {
    _step = next;
    if (!_steps.isClosed) _steps.add(next);
  }

  /// Asks for a code.
  ///
  /// [resend] only changes what is rendered while it is in flight: the request
  /// is identical, and it is the *server* that decides whether a second ask is
  /// a resend or a refusal.
  Future<void> requestCode(String address, {bool resend = false}) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return;

    final current = _step;
    _emit(
      resend && current is AwaitingCode
          ? AwaitingCode(current.challenge, resending: true)
          : SendingCode(trimmed),
    );

    try {
      final challenge = await _gateway.requestCode(trimmed);
      _address = trimmed;
      _resendAvailableAt = _clock.now().add(challenge.resendAfter);
      _emit(AwaitingCode(challenge));
    } on ApiFailure catch (failure) {
      // A refused resend keeps the traveller on the code screen — the code
      // they already have is still good, and sending them back to the address
      // field would strongly suggest otherwise.
      if (resend && current is AwaitingCode) {
        _emit(AwaitingCode(current.challenge, failure: failure));
      } else {
        _emit(NeedsAddress(failure: failure, address: trimmed));
      }
    }
  }

  /// Sends another code to the address the last one went to.
  ///
  /// A no-op before the first send, which is what stops a stray tap on a
  /// stale widget from posting an empty address.
  Future<void> resend() async {
    final address = _address;
    if (address == null) return;
    await requestCode(address, resend: true);
  }

  Future<void> submitCode(String code) async {
    final current = _step;
    if (current is! AwaitingCode) return;

    final trimmed = code.trim();
    if (trimmed.length != 6) return;

    _emit(VerifyingCode(current.challenge));

    try {
      final account = await _gateway.submitCode(
        challengeId: current.challenge.challengeId,
        code: trimmed,
      );
      // `isNewAccount` decides whether to greet or welcome back, and nothing
      // security-relevant hangs on it.
      _emit(SignedIn(account, isNew: account.fullName == null));
    } on ApiFailure catch (failure) {
      _emit(AwaitingCode(current.challenge, failure: failure));
    }
  }

  /// Back to the address field — "not the right address?". The address is
  /// kept so the field is prefilled rather than empty.
  void changeAddress() {
    _resendAvailableAt = null;
    _emit(NeedsAddress(address: _address));
  }

  void reset() {
    _address = null;
    _resendAvailableAt = null;
    _emit(const NeedsAddress());
  }

  Future<void> dispose() => _steps.close();
}
