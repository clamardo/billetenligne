import 'dart:async';

import 'package:bel_backoffice/bel_backoffice.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/console_workspace.dart';
import '../application/onboarding_workspace.dart';
import 'app.dart';
import 'l10n.dart';
import 'screens/onboarding_screen.dart';

/// Signed in or not, and the screen for the second case.
///
/// **The ADR-0013 deviation this file used to document is closed.** The
/// sign-in is still the one-time code a traveller uses — an emailed code is a
/// channel we can measure, and adding a password would add a secret to
/// phish rather than a factor to hold — but it is now followed by a mandatory
/// authenticator for anybody the database calls staff. The flow itself lives
/// in `bel_backoffice`, shared with the admin app, because two
/// implementations of one security control is two chances for one of them to
/// forget the enrolment gate.
///
/// What remains open, and is not pretended otherwise: there is no password,
/// so a compromised inbox plus a compromised authenticator is still a way in,
/// and enrolment is compulsory-on-next-sign-in rather than retroactive.
final class ConsoleRoot extends StatefulWidget {
  const ConsoleRoot({
    required this.catalog,
    required this.session,
    required this.client,
    required this.buildWorkspace,
    this.mode,
    required this.buildOnboarding,
    super.key,
  });

  final TranslationCatalog catalog;
  final BelSession session;
  final BelApiClient client;

  /// The theme choice, so the sign-in screen and the app behind it agree —
  /// a blazing white sign-in in front of a dark console is a seam somebody
  /// notices every single morning.
  final KiloModeController? mode;
  final ConsoleWorkspace Function() buildWorkspace;

  /// Built only for somebody who turns out to belong to no operator. The two
  /// are never alive at once: an applicant has no fleet to load and a
  /// dispatcher has no application to fill in.
  final OnboardingWorkspace Function() buildOnboarding;

  @override
  State<ConsoleRoot> createState() => _ConsoleRootState();
}

class _ConsoleRootState extends State<ConsoleRoot> {
  ConsoleWorkspace? _workspace;

  /// Set when the person who just signed in is staff of nothing. Not an
  /// error: it is what every operator looks like on the day before we
  /// activate them, and showing them a console with six empty tabs would be
  /// showing them a product that appears broken.
  OnboardingWorkspace? _onboarding;

  /// True while we are finding out which of the two they are.
  var _resolving = false;

  /// True while somebody is moving their authenticator to a new phone. Held
  /// here rather than pushed onto a Navigator because it replaces the whole
  /// surface: there is nothing useful to do behind it, and a route stacked
  /// over the work would invite a back gesture out of a half-finished
  /// enrolment.
  var _managingSecondFactor = false;

  /// Console or wizard, decided by the server rather than by a claim in the
  /// token. `/console/v1/me` answers 403 for somebody who belongs to no
  /// tenant — the middleware re-reads membership per request precisely so a
  /// revoked one cannot be carried in a session — so the refusal *is* the
  /// answer, and a client-side guess would be a second opinion about
  /// authorisation.
  Future<void> _resolveSurface() async {
    setState(() => _resolving = true);
    try {
      await widget.client.consoleIdentity();
      if (mounted) setState(() => _workspace = widget.buildWorkspace());
    } on ServerRefused catch (e) {
      if (!mounted) return;
      if (e.status == 403) {
        final onboarding = widget.buildOnboarding();
        setState(() => _onboarding = onboarding);
        unawaited(onboarding.load());
      } else {
        // Any other refusal is the console's own problem to surface — the
        // workspace has a failure banner and a trace id, and inventing a
        // second error surface here would hide it behind a signup form.
        setState(() => _workspace = widget.buildWorkspace());
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = _onboarding;
    if (onboarding != null) {
      return Localized(
        catalog: widget.catalog,
        initialLanguage: 'fr',
        child: MaterialApp(
          title: 'BilletEnLigne — Inscription',
          debugShowCheckedModeBanner: false,
          theme: KiloTheme.materialTheme(),
          darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
          themeMode: (widget.mode?.mode ?? KiloMode.system).materialMode,
          home: StreamBuilder<void>(
            stream: onboarding.changes,
            builder: (context, _) => OnboardingScreen(workspace: onboarding),
          ),
        ),
      );
    }

    // The gap between "the code was right" and "here is your surface" is one
    // request. Blank for that beat reads as a failed sign-in, so it says
    // something instead.
    if (_resolving) {
      return Localized(
        catalog: widget.catalog,
        initialLanguage: 'fr',
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: KiloTheme.materialTheme(),
          darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
          themeMode: (widget.mode?.mode ?? KiloMode.system).materialMode,
          home: const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }

    final workspace = _workspace;
    if (workspace != null) {
      if (_managingSecondFactor) {
        return Localized(
          catalog: widget.catalog,
          initialLanguage: 'fr',
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: KiloTheme.materialTheme(),
            darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
            themeMode: (widget.mode?.mode ?? KiloMode.system).materialMode,
            home: Builder(
              builder: (context) => SecondFactorEnrolment(
                client: widget.client,
                t: context.t,
                onCancel: () => setState(() => _managingSecondFactor = false),
                onFinished: () => setState(() => _managingSecondFactor = false),
              ),
            ),
          ),
        );
      }

      return ConsoleApp(
        mode: widget.mode,
        catalog: widget.catalog,
        workspace: workspace,
        onManageSecondFactor: () =>
            setState(() => _managingSecondFactor = true),
      );
    }

    return Localized(
      catalog: widget.catalog,
      initialLanguage: 'fr',
      child: MaterialApp(
        title: 'BilletEnLigne — Console',
        debugShowCheckedModeBanner: false,
        theme: KiloTheme.materialTheme(),
        darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
        themeMode: (widget.mode?.mode ?? KiloMode.system).materialMode,
        home: Builder(
          builder: (context) => BackOfficeSignIn(
            client: widget.client,
            session: widget.session,
            title: context.t('console.signIn.title'),
            icon: Icons.directions_bus_filled_outlined,
            t: context.t,
            onSignedIn: _resolveSurface,
          ),
        ),
      ),
    );
  }
}
