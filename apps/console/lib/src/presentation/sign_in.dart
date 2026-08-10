import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/console_workspace.dart';
import 'app.dart';
import 'l10n.dart';

/// Signed in or not, and the screen for the second case.
///
/// **A documented deviation from ADR-0013**, which specifies email + password
/// + mandatory TOTP for back-office users. This is the same one-time-code
/// sign-in the traveller app uses, and the reasoning is sequencing rather
/// than disagreement:
///
///   * Today's console can configure a fleet, publish a timetable, sell a
///     ticket and read a manifest. The blast radius of a compromise is an
///     operator's own inventory.
///   * The things ADR-0013 is actually protecting — settlement accounts,
///     payout approval, refunds above a cap — are not built. Payout approval
///     and settlement-account editing do not exist as endpoints at all.
///   * An unusable console is a larger risk to this pilot than a
///     single-factor one, because it is the only thing between the build and
///     an operator selling a real seat.
///
/// **TOTP lands before refunds and payouts do.** That ordering is the whole
/// of the argument, and if refunds ship first this comment is the bug report.
final class ConsoleRoot extends StatefulWidget {
  const ConsoleRoot({
    required this.catalog,
    required this.session,
    required this.client,
    required this.buildWorkspace,
    super.key,
  });

  final TranslationCatalog catalog;
  final BelSession session;
  final BelApiClient client;
  final ConsoleWorkspace Function() buildWorkspace;

  @override
  State<ConsoleRoot> createState() => _ConsoleRootState();
}

class _ConsoleRootState extends State<ConsoleRoot> {
  ConsoleWorkspace? _workspace;

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    if (workspace != null) {
      return ConsoleApp(catalog: widget.catalog, workspace: workspace);
    }

    return Localized(
      catalog: widget.catalog,
      initialLanguage: 'fr',
      child: MaterialApp(
        title: 'BilletEnLigne — Console',
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
                  Icons.directions_bus,
                  size: 40,
                  color: kilo.color.brandPrimary,
                ),
                SizedBox(height: kilo.space.s3),
                Text(
                  context.t('console.signIn.title'),
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
