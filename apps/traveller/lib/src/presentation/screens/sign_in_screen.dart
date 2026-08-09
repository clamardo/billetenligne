import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/sign_in_flow.dart';
import '../l10n.dart';

/// The only screen that stands between a chosen seat and a held one.
///
/// It appears at the moment of holding and nowhere else (ADR-0013). By the
/// time somebody sees it they have already seen the coach, the seat and the
/// total — so this reads as "where shall we send your ticket?" rather than as
/// a gate they have to pass before being allowed to look.
///
/// Four decisions here are worth more than they look:
///
///   * **No password field, and it says so.** The reassurance line is not
///     marketing: a person who expects to have to remember a password and
///     cannot is a person who abandons the purchase.
///   * **The resend countdown comes from the server**, through the flow. A
///     client-side timer is a suggestion the server has never heard of, and
///     the two drifting apart produces a button that looks ready and is not.
///   * **The code field takes six digits and nothing else**, autofocused, with
///     the numeric keyboard up. Six taps and a submit.
///   * **A wrong code never leaves the screen.** The email is in their inbox;
///     bouncing them back to the address field to retype it is how the attempt
///     is lost.
final class SignInScreen extends StatefulWidget {
  const SignInScreen({
    required this.flow,
    required this.onSignedIn,
    required this.onCancel,
    this.now,
    super.key,
  });

  final SignInFlow flow;

  /// Called once, when the traveller is signed in. The funnel resumes the hold
  /// they were interrupted in the middle of.
  final ValueChanged<SignInStep> onSignedIn;

  /// Backing out. Their seats are still selected.
  final VoidCallback onCancel;

  /// Injectable for tests. The resend countdown is the thing worth testing at
  /// the moment it reaches zero, and a widget reading the wall clock cannot be.
  final DateTime Function()? now;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _address = TextEditingController();
  final _code = TextEditingController();

  StreamSubscription<SignInStep>? _subscription;
  Timer? _ticker;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _subscription = widget.flow.steps.listen((step) {
      if (!mounted) return;
      if (step is SignedIn) {
        widget.onSignedIn(step);
        return;
      }
      // A fresh challenge means a fresh code. Clearing the field stops the
      // previous, now-dead code sitting there looking submittable.
      if (step is AwaitingCode && step.failure == null) _code.clear();
      setState(() {});
    });

    // One second, and only while this screen is mounted. It exists solely to
    // redraw the resend countdown.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _subscription?.cancel();
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final step = widget.flow.step;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onCancel),
        title: Text(context.t('auth.gate.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: switch (step) {
            NeedsAddress() || SendingCode() => _addressStep(context, step),
            AwaitingCode() || VerifyingCode() => _codeStep(context, step),
            // Handled by the listener above; the funnel has already moved on.
            SignedIn() => const [SizedBox.shrink()],
          },
        ),
      ),
    );
  }

  // ── Step one: the address ─────────────────────────────────────────────────

  List<Widget> _addressStep(BuildContext context, SignInStep step) {
    final kilo = context.kilo;
    final sending = step is SendingCode;
    final failure = step is NeedsAddress ? step.failure : null;

    if (step is NeedsAddress && step.address != null && _address.text.isEmpty) {
      // Retyping an email on a phone keyboard because the server said "wait
      // forty seconds" is how somebody abandons a purchase.
      _address.text = step.address!;
    }

    return [
      Text(context.t('auth.gate.intro'), style: kilo.text.body),
      SizedBox(height: kilo.space.s2),
      Text(
        context.t('auth.gate.reassurance'),
        style: kilo.text.bodySm.copyWith(color: kilo.color.contentSecondary),
      ),
      SizedBox(height: kilo.space.s5),
      KField(
        label: context.t('auth.email.label'),
        hint: context.t('auth.email.hint'),
        controller: _address,
        keyboardType: TextInputType.emailAddress,
        autofocus: true,
        enabled: !sending,
        error: failure == null ? null : _message(context, failure),
        onChanged: (_) => setState(() {}),
      ),
      SizedBox(height: kilo.space.s5),
      KButton(
        label: context.t('auth.email.submit'),
        loading: sending,
        onPressed: _address.text.trim().isEmpty
            ? null
            : () => widget.flow.requestCode(_address.text),
      ),
      SizedBox(height: kilo.space.s4),
      // Phone is the channel this market actually prefers and it is second,
      // not absent (ADR-0024). Saying so is more honest than a control that
      // is simply missing.
      Text(
        context.t('auth.phone.unavailable'),
        style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        textAlign: TextAlign.center,
      ),
    ];
  }

  // ── Step two: the code ────────────────────────────────────────────────────

  List<Widget> _codeStep(BuildContext context, SignInStep step) {
    final kilo = context.kilo;
    final verifying = step is VerifyingCode;
    final awaiting = step is AwaitingCode ? step : null;
    final challenge = awaiting?.challenge ?? (step as VerifyingCode).challenge;

    final wait = widget.flow.resendWaitAt(_now());
    final canResend = wait == Duration.zero && !verifying;

    return [
      Text(context.t('auth.code.title'), style: kilo.text.h2),
      SizedBox(height: kilo.space.s2),
      Text(
        context.t('auth.code.sentTo', {'destination': challenge.sentTo}),
        style: kilo.text.body,
      ),
      SizedBox(height: kilo.space.s5),
      KField(
        label: context.t('auth.code.label'),
        controller: _code,
        keyboardType: TextInputType.number,
        autofocus: true,
        enabled: !verifying,
        maxLength: 6,
        error: awaiting?.failure == null
            ? null
            : _message(context, awaiting!.failure!),
        onChanged: (value) {
          setState(() {});
          // Six digits is the whole code. Submitting on the sixth saves a tap
          // that is easy to miss on a cracked screen.
          if (value.trim().length == 6) widget.flow.submitCode(value);
        },
      ),
      SizedBox(height: kilo.space.s5),
      KButton(
        label: context.t('auth.code.submit'),
        loading: verifying,
        onPressed: _code.text.trim().length == 6
            ? () => widget.flow.submitCode(_code.text)
            : null,
        disabledHint: context.t('auth.code.label'),
      ),
      SizedBox(height: kilo.space.s3),
      KButton(
        label: canResend
            ? context.t('auth.code.resend')
            : context.t('auth.code.resendIn', {'seconds': wait.inSeconds}),
        tone: KButtonTone.ghost,
        loading: awaiting?.resending ?? false,
        // `flow.resend()`, not the address on screen: `challenge.sentTo` is
        // masked, and sending a code to a string of asterisks is a bug that
        // looks like a delivery failure.
        onPressed: canResend ? widget.flow.resend : null,
      ),
      KButton(
        label: context.t('auth.code.wrongAddress'),
        tone: KButtonTone.ghost,
        onPressed: verifying ? null : widget.flow.changeAddress,
      ),
    ];
  }

  /// A failure code becomes a sentence here and nowhere else. The client never
  /// produces prose; it produces a catalog key and parameters (ADR-0008).
  String _message(BuildContext context, ApiFailure failure) => context.t(
    failure.messageKey,
    failure is ServerRefused ? failure.params : const {},
  );
}
