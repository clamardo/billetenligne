import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/foundation.dart';
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
    this.scene = KSceneArt.station,
    this.webSession = kIsWeb,
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

  /// The artwork behind the form.
  ///
  /// A bus station by default, because that is where the people who sign in
  /// here are standing. The scanner passes [KSceneArt.scan] — a conductor
  /// opens it at the coach door, not in an office — and the two back offices
  /// keep the station.
  ///
  /// It is not decoration in the sense of being optional. This screen used to
  /// be a forty-pixel icon and two fields centred on the bare surface colour,
  /// and it was the first screen every member of staff met: three of the four
  /// apps opened on a white sheet that could have belonged to any product.
  final KSceneArt scene;

  /// Ask the server for a cookie session rather than a token (J11).
  ///
  /// Defaults to "this is a browser", which is the honest predicate: a
  /// browser has nowhere safe to keep a credential, and both back offices
  /// ship as web apps. A native build of either — there is none today — would
  /// pass false and exchange for itself, the way the handset does.
  final bool webSession;

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

    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: kilo.text.h2),
        SizedBox(height: kilo.space.s5),
        ...switch (_step) {
          _Step.address => _address(context),
          _Step.code => _code_(context),
          _Step.secondFactor => _factor(context),
          _Step.enrol => const [],
        },
      ],
    );

    return Scaffold(
      // The brand is the ground, not a detail on it. Underneath everything is
      // the same woven field the apps carry, so the surface never shows.
      body: KPattern(
        motif: KPatternMotif.kuba,
        background: kilo.color.brandPrimary,
        color: kilo.color.onBrandPrimary,
        opacity: 0.10,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Two panes when there is width for them — the back offices are
            // worked in a browser on a desk — and a band over a card when
            // there is not, which is the scanner on a handset.
            final wide = constraints.maxWidth >= 840;
            final card = _Panel(
              icon: widget.icon,
              child: fields,
            );

            if (wide) {
              return Row(
                children: [
                  Expanded(
                    child: KScene(
                      widget.scene,
                      height: constraints.maxHeight,
                      overlay: false,
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(kilo.space.s6),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: card,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                KScene(
                  widget.scene,
                  height: (constraints.maxHeight * 0.3).clamp(140.0, 260.0),
                  overlay: false,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(kilo.space.s5),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: card,
                    ),
                  ),
                ),
              ],
            );
          },
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
        webSession: widget.webSession,
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
        webSession: widget.webSession,
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
    //
    // adoptGranted rather than adopt: both routes here arrive with a code the
    // server has already accepted and consumed, so a failure at this point
    // must not read as "wrong code".
    await widget.session.adoptGranted(session);
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


/// The form, raised off the woven ground.
///
/// A card rather than fields floating on the pattern: six digits typed under
/// pressure at a coach door need a quiet white field to sit in, and the
/// contrast gate has one surface to reason about instead of one per motif.
class _Panel extends StatelessWidget {
  const _Panel({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kilo.color.surfaceRaised,
        borderRadius: BorderRadius.circular(kilo.space.s4),
        boxShadow: [
          BoxShadow(
            color: kilo.color.contentPrimary.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(kilo.space.s5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Icon(icon, size: 32, color: kilo.color.brandPrimary),
            ),
            SizedBox(height: kilo.space.s3),
            child,
          ],
        ),
      ),
    );
  }
}
