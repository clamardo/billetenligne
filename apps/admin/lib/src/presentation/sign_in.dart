import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/admin_workspace.dart';
import 'app.dart';
import 'l10n.dart';

/// Signed in or not, and the screen for the second case.
///
/// **The largest open deviation from ADR-0013 in the build**, and a larger
/// one than the console's. This is the same one-time-code sign-in a traveller
/// uses, and the surface behind it reaches across every tenant: it can
/// approve an operator, change what we charge them, and declare a payment
/// captured.
///
/// It is written down rather than hidden because the sequencing is the
/// argument, and the argument is weaker here:
///
///   * a code to an email inbox is one factor, and the person holding it is
///     one phished inbox away from our whole roster;
///   * the compensating control today is that **everything on this surface is
///     audited with an actor and a reason** and none of it moves money out —
///     payout approval and settlement-account editing are not endpoints at
///     all;
///   * the back office is unusable without some way in, and an unusable back
///     office means an `indeterminate` payment nobody can settle.
///
/// **TOTP lands before payouts do, and before this app leaves the pilot.**
/// That ordering is the whole of the argument; if a payout run ships first,
/// this comment is the bug report.
final class AdminRoot extends StatefulWidget {
  const AdminRoot({
    required this.catalog,
    required this.session,
    required this.client,
    required this.buildWorkspace,
    super.key,
  });

  final TranslationCatalog catalog;
  final BelSession session;
  final BelApiClient client;
  final AdminWorkspace Function() buildWorkspace;

  @override
  State<AdminRoot> createState() => _AdminRootState();
}

class _AdminRootState extends State<AdminRoot> {
  AdminWorkspace? _workspace;

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    if (workspace != null) {
      return AdminApp(catalog: widget.catalog, workspace: workspace);
    }

    return Localized(
      catalog: widget.catalog,
      initialLanguage: 'fr',
      child: MaterialApp(
        title: 'BilletEnLigne — Back office',
        debugShowCheckedModeBanner: false,
        theme: KiloTheme.materialTheme(),
        home: _SignInScreen(
          client: widget.client,
          session: widget.session,
          onSignedIn: () =>
              setState(() => _workspace = widget.buildWorkspace()),
        ),
      ),
    );
  }
}

class _SignInScreen extends StatefulWidget {
  const _SignInScreen({
    required this.client,
    required this.session,
    required this.onSignedIn,
  });

  final BelApiClient client;
  final BelSession session;
  final VoidCallback onSignedIn;

  @override
  State<_SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<_SignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();

  SignInChallengeDto? _challenge;
  ApiFailure? _failure;
  var _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(kilo.space.s5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 40,
                  color: kilo.color.brandPrimary,
                ),
                SizedBox(height: kilo.space.s3),
                Text(
                  context.t('admin.signIn.title'),
                  style: kilo.text.h2,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: kilo.space.s5),

                if (_challenge == null) ...[
                  KField(
                    label: context.t('auth.email.label'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofocus: true,
                    enabled: !_busy,
                    error: _message(context),
                    onChanged: (_) => setState(() {}),
                  ),
                  SizedBox(height: kilo.space.s4),
                  KButton(
                    label: context.t('auth.email.submit'),
                    loading: _busy,
                    onPressed:
                        _email.text.trim().isEmpty ? null : _requestCode,
                  ),
                ] else ...[
                  Text(
                    context.t('auth.code.sentTo', {
                      'destination': _challenge!.sentTo,
                    }),
                    style: kilo.text.body,
                  ),
                  SizedBox(height: kilo.space.s3),
                  KField(
                    label: context.t('auth.code.label'),
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
                  SizedBox(height: kilo.space.s4),
                  KButton(
                    label: context.t('auth.code.submit'),
                    loading: _busy,
                    onPressed:
                        _code.text.trim().length == 6 ? _submitCode : null,
                  ),
                  SizedBox(height: kilo.space.s2),
                  KButton(
                    label: context.t('auth.code.wrongAddress'),
                    tone: KButtonTone.ghost,
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _challenge = null;
                            _failure = null;
                            _code.clear();
                          }),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _message(BuildContext context) => _failure == null
      ? null
      : context.t(
          _failure!.messageKey,
          _failure is ServerRefused
              ? (_failure! as ServerRefused).params
              : const {},
        );

  Future<void> _requestCode() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final challenge = await widget.client.startSignIn(
        StartSignInRequest.email(_email.text.trim()),
      );
      if (mounted) setState(() => _challenge = challenge);
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitCode() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final session = await widget.client.verifySignIn(
        VerifySignInRequest(
          challengeId: _challenge!.challengeId,
          code: _code.text.trim(),
        ),
      );
      // Exchanges the custom token for a Firebase session before the console
      // opens. Until that returns nobody is signed in, which is why the
      // callback is here and not on the response above.
      await widget.session.adopt(session);
      if (mounted) widget.onSignedIn();
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
