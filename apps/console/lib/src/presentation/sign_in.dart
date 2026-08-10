import 'package:bel_backoffice/bel_backoffice.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/console_workspace.dart';
import 'app.dart';
import 'l10n.dart';

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

  /// True while somebody is moving their authenticator to a new phone. Held
  /// here rather than pushed onto a Navigator because it replaces the whole
  /// surface: there is nothing useful to do behind it, and a route stacked
  /// over the work would invite a back gesture out of a half-finished
  /// enrolment.
  var _managingSecondFactor = false;

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    if (workspace != null) {
      if (_managingSecondFactor) {
        return Localized(
          catalog: widget.catalog,
          initialLanguage: 'fr',
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: KiloTheme.materialTheme(),
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
        home: Builder(
          builder: (context) => BackOfficeSignIn(
            client: widget.client,
            session: widget.session,
            title: context.t('console.signIn.title'),
            icon: Icons.directions_bus_filled_outlined,
            t: context.t,
            onSignedIn: () =>
                setState(() => _workspace = widget.buildWorkspace()),
          ),
        ),
      ),
    );
  }
}
