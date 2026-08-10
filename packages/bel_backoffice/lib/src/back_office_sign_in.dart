import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import 'second_factor_enrolment.dart';

/// How a shared widget reaches a sentence.
///
/// Passed in rather than read from an inherited scope, because the Flutter
/// side of the catalog — the `Localized` widget and its `context.t` — lives in
/// each app rather than in a package: `bel_localization` is pure Dart so the
/// API can read the same YAML from disk, and it therefore cannot declare a
/// Flutter dependency. A function is the smaller seam, and it makes these
/// screens testable with no catalog at all.
typedef Translate = String Function(String key, [Map<String, Object?> args]);

/// Where a staff sign-in currently is.
enum _Step { address, code, secondFactor, enrol }

/// The way into a back office.
///
/// One widget for both surfaces, and the reason is the second factor rather
/// than tidiness. ADR-0013 obliges everybody who can move other people's
/// money to hold an authenticator; a console that implemented that
/// obligation separately from the admin app would be a console that could
/// forget the enrolment gate in one release and nobody would notice until an
/// audit.
///
/// The flow has four states and the awkward one is the fourth:
///
///   * **address** — an email, because that is the channel we can send on;
///   * **code** — the emailed one-time code, which is the *first* factor;
///   * **secondFactor** — six digits from an authenticator, or a recovery
///     code for the phone that fell in the river. Reached only when the
///     server withholds the session, which it decides from the database;
///   * **enrol** — staff who signed in with nothing enrolled. They hold a
///     real session and this screen is the only thing they are shown until
///     they finish. Refusing the session instead would have locked out every
///     existing staff account the hour this shipped, including the people who
///     would have to fix it.
///
/// Nothing here decides whether a factor is required. That is read from the
/// server's answer, because a client that decided it is a client an attacker
/// can edit.
final class BackOfficeSignIn extends StatefulWidget {
  const BackOfficeSignIn({
    required this.client,
    required this.session,
    required this.onSignedIn,
    required this.title,
    required this.t,
    this.icon = Icons.shield_outlined,
    super.key,
  });

  final BelApiClient client;
  final BelSession session;
  final VoidCallback onSignedIn;
  final Translate t;

  /// Already translated by the caller: the two surfaces name themselves
  /// differently and neither name belongs in a shared widget.
  final String title;

  final IconData icon;

  @override
  State<BackOfficeSignIn> createState() => _BackOfficeSignInState();
}

class _BackOfficeSignInState extends State<BackOfficeSignIn> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _factorCode = TextEditingController();
  final _recovery = TextEditingController();

  var _step = _Step.address;
  SignInChallengeDto? _challenge;
  SessionDto? _pending;
  ApiFailure? _failure;
  var _busy = false;
  var _usingRecovery = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _factorCode.dispose();
    _recovery.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    if (_step == _Step.enrol) {
      return SecondFactorEnrolment(
        client: widget.client,
        t: widget.t,
        onFinished: widget.onSignedIn,
      );
    }

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(kilo.space.s5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(widget.icon, size: 40, color: kilo.color.brandPrimary),
                SizedBox(height: kilo.space.s3),
                Text(
                  widget.title,
                  style: kilo.text.h2,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: kilo.space.s5),
                ...switch (_step) {
                  _Step.address => _address(context),
                  _Step.code => _code_(context),
                  _Step.secondFactor => _factor(context),
                  _Step.enrol => const [],
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _address(BuildContext context) => [
    KField(
      label: widget.t('auth.email.label'),
      controller: _email,
      keyboardType: TextInputType.emailAddress,
      autofocus: true,
      enabled: !_busy,
      error: _message(context),
      onChanged: (_) => setState(() {}),
    ),
    SizedBox(height: context.kilo.space.s4),
    KButton(
      label: widget.t('auth.email.submit'),
      loading: _busy,
      onPressed: _email.text.trim().isEmpty ? null : _requestCode,
    ),
  ];

  List<Widget> _code_(BuildContext context) => [
    Text(
      widget.t('auth.code.sentTo', {'destination': _challenge!.sentTo}),
      style: context.kilo.text.body,
    ),
    SizedBox(height: context.kilo.space.s3),
    KField(
      label: widget.t('auth.code.label'),
      controller: _code,
      keyboardType: TextInputType.number,
      autofocus: true,
      maxLength: 6,
      enabled: !_busy,
      error: _message(context),
      onChanged: (value) {
        setState(() {});
        if (value.trim().length == 6) _submitCode();
      },
    ),
    SizedBox(height: context.kilo.space.s4),
    KButton(
      label: widget.t('auth.code.submit'),
      loading: _busy,
      onPressed: _code.text.trim().length == 6 ? _submitCode : null,
    ),
    SizedBox(height: context.kilo.space.s2),
    KButton(
      label: widget.t('auth.code.wrongAddress'),
      tone: KButtonTone.ghost,
      onPressed: _busy ? null : _startOver,
    ),
  ];

  List<Widget> _factor(BuildContext context) => [
    Text(widget.t('auth.mfa.intro'), style: context.kilo.text.body),
    SizedBox(height: context.kilo.space.s3),
    if (_usingRecovery)
      KField(
        label: widget.t('auth.mfa.recoveryLabel'),
        hint: widget.t('auth.mfa.recoveryHint'),
        controller: _recovery,
        autofocus: true,
        enabled: !_busy,
        error: _message(context),
        onChanged: (_) => setState(() {}),
      )
    else
      KField(
        label: widget.t('auth.mfa.label'),
        controller: _factorCode,
        keyboardType: TextInputType.number,
        autofocus: true,
        maxLength: 6,
        enabled: !_busy,
        error: _message(context),
        onChanged: (value) {
          setState(() {});
          // Submitted on the sixth digit, like the emailed code. A code that
          // is only valid for thirty seconds should not also be waiting on
          // somebody to find the button.
          if (value.trim().length == 6) _submitFactor();
        },
      ),
    SizedBox(height: context.kilo.space.s4),
    KButton(
      label: widget.t('auth.mfa.submit'),
      loading: _busy,
      onPressed: _canSubmitFactor ? _submitFactor : null,
    ),
    SizedBox(height: context.kilo.space.s2),
    KButton(
      label: widget.t(
        _usingRecovery ? 'auth.mfa.useCode' : 'auth.mfa.useRecovery',
      ),
      tone: KButtonTone.ghost,
      onPressed: _busy
          ? null
          : () => setState(() {
              _usingRecovery = !_usingRecovery;
              _failure = null;
            }),
    ),
  ];

  bool get _canSubmitFactor => _usingRecovery
      ? _recovery.text.trim().length >= 10
      : _factorCode.text.trim().length == 6;

  String? _message(BuildContext context) => _failure == null
      ? null
      : widget.t(
          _failure!.messageKey,
          _failure is ServerRefused
              ? (_failure! as ServerRefused).params
              : const {},
        );

  void _startOver() => setState(() {
    _step = _Step.address;
    _challenge = null;
    _pending = null;
    _failure = null;
    _code.clear();
    _factorCode.clear();
    _recovery.clear();
  });

  Future<void> _requestCode() => _run(() async {
    final challenge = await widget.client.startSignIn(
      StartSignInRequest.email(_email.text.trim()),
    );
    setState(() {
      _challenge = challenge;
      _step = _Step.code;
    });
  });

  Future<void> _submitCode() => _run(() async {
    final session = await widget.client.verifySignIn(
      VerifySignInRequest(
        challengeId: _challenge!.challengeId,
        code: _code.text.trim(),
      ),
    );
    await _adopt(session);
  });

  Future<void> _submitFactor() => _run(() async {
    final session = await widget.client.verifySecondFactor(
      VerifySecondFactorRequest(
        mfaToken: _pending!.mfaToken!,
        code: _usingRecovery ? null : _factorCode.text.trim(),
        recoveryCode: _usingRecovery ? _recovery.text.trim() : null,
      ),
    );
    await _adopt(session);
  });

  /// Takes the server's answer at face value, whichever of the three it is.
  Future<void> _adopt(SessionDto session) async {
    if (session.needsSecondFactor) {
      setState(() {
        _pending = session;
        _step = _Step.secondFactor;
        _factorCode.clear();
        _recovery.clear();
      });
      return;
    }

    // Exchanges the custom token for a Firebase session before anything
    // opens. Until that returns nobody is signed in, which is why the
    // callback is below it and not on the response.
    await widget.session.adopt(session);
    if (!mounted) return;

    if (session.mustEnrolSecondFactor) {
      setState(() => _step = _Step.enrol);
      return;
    }
    widget.onSignedIn();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await work();
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
