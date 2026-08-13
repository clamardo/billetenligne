import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'back_office_sign_in.dart' show Translate;

/// Setting up an authenticator, on either back office.
///
/// Reached two ways: as the only screen a staff member with nothing enrolled
/// is shown, and later from the shell when somebody replaces a phone.
///
/// **There is no QR code, and that is a decision rather than an omission.**
/// A QR encoder is a few hundred lines of Reed–Solomon, and this repository
/// has no independent decoder to check it against — so a bug in it would ship
/// as a code that scans cleanly and produces a factor that never matches. The
/// setup key is typed instead, in groups of four, which every authenticator
/// app accepts as manual entry. A QR belongs here the day there is something
/// that can prove the one we draw is the one we meant.
///
/// The recovery codes are shown **once**. The server keeps only their HMACs,
/// so this screen is the only place they exist in readable form — which is
/// why leaving it is a deliberate act with a button, rather than something
/// that happens when the next screen loads.
final class SecondFactorEnrolment extends StatefulWidget {
  const SecondFactorEnrolment({
    required this.client,
    required this.onFinished,
    required this.t,
    this.onCancel,
    super.key,
  });

  final BelApiClient client;
  final Translate t;

  /// Called when the factor is confirmed and the codes have been kept.
  final VoidCallback onFinished;

  /// Null when enrolment is compulsory — which is the case for somebody the
  /// server has just told to enrol. There is nowhere for them to go.
  final VoidCallback? onCancel;

  @override
  State<SecondFactorEnrolment> createState() => _SecondFactorEnrolmentState();
}

class _SecondFactorEnrolmentState extends State<SecondFactorEnrolment> {
  final _code = TextEditingController();

  SecondFactorStatusDto? _status;
  SecondFactorEnrolmentDto? _enrolment;
  ApiFailure? _failure;
  var _busy = false;
  var _confirmed = false;
  var _copied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final enrolment = _enrolment;
    final status = _status;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(kilo.space.s5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: switch (this) {
                // A factor already in place. Replacing it starts by removing
                // it, deliberately and with a button — the server refuses a
                // silent overwrite, because a stray click would otherwise
                // lock out whoever's phone still holds the old secret.
                _ when enrolment == null && (status?.enrolled ?? false) =>
                  _manage(context, status!),
                _ when enrolment != null && _confirmed => _recovery(
                  context,
                  enrolment,
                ),
                _ when enrolment != null => _setup(context, enrolment),
                _ => [
                  KStateView(
                    _failure == null
                        ? KLoading(widget.t('common.state.loading'))
                        : KFailed(
                            title: widget.t('common.state.errorTitle'),
                            body: widget.t(_failure!.messageKey),
                            retryLabel: widget.t('common.actions.retry'),
                            onRetry: _load,
                          ),
                  ),
                ],
              },
            ),
          ),
        ),
      ),
    );
  }

  /// What somebody who already has an authenticator is shown.
  List<Widget> _manage(BuildContext context, SecondFactorStatusDto status) {
    final kilo = context.kilo;
    return [
      Icon(Icons.verified_user_outlined, size: 40, color: kilo.color.success),
      SizedBox(height: kilo.space.s3),
      Text(
        widget.t('auth.enrol.manage'),
        style: kilo.text.h2,
        textAlign: TextAlign.center,
      ),
      SizedBox(height: kilo.space.s3),
      Text(widget.t('auth.enrol.done'), style: kilo.text.body),
      SizedBox(height: kilo.space.s2),
      // Says how many are left, because somebody down to their last code is
      // one lost phone from the support call this screen exists to avoid.
      Text(
        widget.t('auth.enrol.remaining', {
          'count': status.recoveryCodesRemaining,
        }),
        style: kilo.text.bodySm.copyWith(color: kilo.color.contentMuted),
      ),
      SizedBox(height: kilo.space.s4),
      KButton(
        label: widget.t('auth.enrol.disable'),
        tone: KButtonTone.danger,
        loading: _busy,
        onPressed: _replace,
      ),
      if (widget.onCancel != null) ...[
        SizedBox(height: kilo.space.s2),
        KButton(
          label: widget.t('common.actions.cancel'),
          tone: KButtonTone.ghost,
          onPressed: _busy ? null : widget.onCancel,
        ),
      ],
    ];
  }

  List<Widget> _setup(BuildContext context, SecondFactorEnrolmentDto e) {
    final kilo = context.kilo;
    return [
      Icon(Icons.lock_outline, size: 40, color: kilo.color.brandPrimary),
      SizedBox(height: kilo.space.s3),
      Text(
        widget.t('auth.enrol.title'),
        style: kilo.text.h2,
        textAlign: TextAlign.center,
      ),
      SizedBox(height: kilo.space.s3),
      // Says why, once, in a sentence. A control somebody does not understand
      // is a control they will route around.
      Text(widget.t('auth.enrol.why'), style: kilo.text.body),
      SizedBox(height: kilo.space.s4),
      Text(widget.t('auth.enrol.step1'), style: kilo.text.body),
      SizedBox(height: kilo.space.s2),
      Text(widget.t('auth.enrol.step2'), style: kilo.text.body),
      SizedBox(height: kilo.space.s3),
      ProvisioningQr(
        uri: e.provisioningUri,
        label: widget.t('auth.enrol.qrLabel'),
      ),
      SizedBox(height: kilo.space.s4),
      // The typed key stays. A back office is opened on a laptop with no
      // camera pointed at it far more often than this screen assumes, and an
      // authenticator on the same machine cannot scan its own screen.
      Text(widget.t('auth.enrol.step2Manual'), style: kilo.text.bodySm),
      SizedBox(height: kilo.space.s2),
      _SetupKey(
        secret: e.secretBase32,
        label: widget.t('auth.enrol.secretLabel'),
        copiedLabel: widget.t('auth.enrol.copied'),
        copied: _copied,
        onCopy: () async {
          await Clipboard.setData(ClipboardData(text: e.secretBase32));
          if (mounted) setState(() => _copied = true);
        },
      ),
      SizedBox(height: kilo.space.s4),
      Text(widget.t('auth.enrol.step3'), style: kilo.text.body),
      SizedBox(height: kilo.space.s2),
      KField(
        label: widget.t('auth.mfa.label'),
        controller: _code,
        keyboardType: TextInputType.number,
        maxLength: 6,
        enabled: !_busy,
        error: _message(context),
        onChanged: (value) {
          setState(() {});
          if (value.trim().length == 6) _confirm();
        },
      ),
      SizedBox(height: kilo.space.s4),
      KButton(
        label: widget.t('auth.enrol.confirm'),
        loading: _busy,
        onPressed: _code.text.trim().length == 6 ? _confirm : null,
      ),
      if (widget.onCancel != null) ...[
        SizedBox(height: kilo.space.s2),
        KButton(
          label: widget.t('common.actions.cancel'),
          tone: KButtonTone.ghost,
          onPressed: _busy ? null : widget.onCancel,
        ),
      ],
    ];
  }

  List<Widget> _recovery(BuildContext context, SecondFactorEnrolmentDto e) {
    final kilo = context.kilo;
    return [
      Icon(Icons.check_circle_outline, size: 40, color: kilo.color.success),
      SizedBox(height: kilo.space.s3),
      Text(
        widget.t('auth.enrol.recoveryTitle'),
        style: kilo.text.h2,
        textAlign: TextAlign.center,
      ),
      SizedBox(height: kilo.space.s3),
      Text(widget.t('auth.enrol.recoveryIntro'), style: kilo.text.body),
      SizedBox(height: kilo.space.s4),
      Container(
        padding: EdgeInsets.all(kilo.space.s4),
        decoration: BoxDecoration(
          color: kilo.color.surfaceSunken,
          borderRadius: BorderRadius.all(kilo.radius.md),
        ),
        child: Wrap(
          spacing: kilo.space.s5,
          runSpacing: kilo.space.s2,
          children: [
            for (final code in e.recoveryCodes)
              SelectableText(code, style: kilo.text.code),
          ],
        ),
      ),
      SizedBox(height: kilo.space.s4),
      KButton(
        label: widget.t('auth.enrol.recoveryKept'),
        onPressed: widget.onFinished,
      ),
    ];
  }

  String? _message(BuildContext context) => _failure == null
      ? null
      : widget.t(
          _failure!.messageKey,
          _failure is ServerRefused
              ? (_failure! as ServerRefused).params
              : const {},
        );

  /// Status first, then enrolment — never the other way round.
  ///
  /// Calling `beginSecondFactor` blind would 409 for everybody who already
  /// has one, which is exactly the person most likely to open this screen.
  Future<void> _load() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final status = await widget.client.secondFactor();
      if (!mounted) return;
      setState(() => _status = status);
      if (!status.enrolled) await _begin();
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Removes the live factor and starts a fresh enrolment in one gesture.
  ///
  /// One button rather than two screens, because "remove" on its own leaves
  /// somebody with *no* factor on a surface that requires one — a state worth
  /// passing through in a single request, not one to park a person in.
  Future<void> _replace() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await widget.client.disableSecondFactor();
      if (!mounted) return;
      setState(() => _status = null);
      await _begin();
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _begin() async {
    setState(() => _failure = null);
    try {
      final enrolment = await widget.client.beginSecondFactor();
      if (mounted) setState(() => _enrolment = enrolment);
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await widget.client.confirmSecondFactor(_code.text.trim());
      if (mounted) setState(() => _confirmed = true);
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The `otpauth://` URI as a QR, black on white in both themes.
///
/// The encoder is `package:qr`, which is the one the API draws a boarding
/// pass with — and that path's PNG output is decoded by a real zlib decoder
/// and compared module by module in its own test. This screen went without a
/// QR for a long time on the argument that there was no independent check on
/// an encoder; there is one now, and it is the same encoder.
///
/// **White card in both themes, on purpose.** The reader is a phone camera
/// held up to a screen, and a dark-theme QR is one many of them refuse.
///
/// The secret is inside this image. It is the same secret printed in full
/// underneath it, on a screen that is only reachable by somebody already
/// holding a session — so the QR adds a way to read it, not a way to reach it.
class ProvisioningQr extends StatelessWidget {
  const ProvisioningQr({required this.uri, required this.label, super.key});

  final String uri;
  final String label;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Center(
      child: Semantics(
        label: label,
        image: true,
        child: Container(
          padding: EdgeInsets.all(kilo.space.s3),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.all(kilo.radius.md),
            border: Border.all(color: kilo.color.borderSubtle),
          ),
          child: QrImageView(
            data: uri,
            version: QrVersions.auto,
            size: 180,
            // Matches the ticket's own code (ADR-0007): M, and a quiet zone
            // rather than none. Higher correction is denser, and density is
            // what kills a scan on a cracked screen.
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            padding: EdgeInsets.zero,
            backgroundColor: const Color(0xFFFFFFFF),
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: Color(0xFF000000),
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.square,
              color: Color(0xFF000000),
            ),
          ),
        ),
      ),
    );
  }
}

/// The setup key, in groups of four.
///
/// Thirty-two characters in one run is a string somebody mistypes; four at a
/// time is the grouping every bank statement and every serial number already
/// uses, and it is the difference between one attempt and three.
class _SetupKey extends StatelessWidget {
  const _SetupKey({
    required this.secret,
    required this.label,
    required this.copiedLabel,
    required this.copied,
    required this.onCopy,
  });

  final String secret;
  final String label;
  final String copiedLabel;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final grouped = [
      for (var i = 0; i < secret.length; i += 4)
        secret.substring(i, i + 4 > secret.length ? secret.length : i + 4),
    ].join(' ');

    return Container(
      padding: EdgeInsets.all(kilo.space.s4),
      decoration: BoxDecoration(
        color: kilo.color.surfaceSunken,
        borderRadius: BorderRadius.all(kilo.radius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: kilo.text.caption.copyWith(color: kilo.color.contentMuted),
          ),
          SizedBox(height: kilo.space.s2),
          SelectableText(grouped, style: kilo.text.code),
          SizedBox(height: kilo.space.s2),
          KButton(
            label: copied ? copiedLabel : label,
            tone: KButtonTone.ghost,
            icon: copied ? Icons.check : Icons.copy_outlined,
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}
