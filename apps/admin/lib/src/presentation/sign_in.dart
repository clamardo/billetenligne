import 'package:bel_backoffice/bel_backoffice.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/admin_workspace.dart';
import 'app.dart';
import 'l10n.dart';

/// Signed in or not, and the screen for the second case.
///
/// **The ADR-0013 deviation this file used to document is closed**, and it
/// mattered most here: this surface reaches across every tenant — it can
/// approve an operator, change what we charge them, and declare a payment
/// captured. Every one of those is audited with an actor and a reason, and
/// now every one of them is behind an authenticator as well.
///
/// The flow lives in `bel_backoffice`, shared with the console, because two
/// implementations of one security control is two chances for one of them to
/// forget the enrolment gate.
///
/// What remains open, and is not pretended otherwise: there is no password,
/// so this is an emailed code plus an authenticator rather than the three
/// factors ADR-0013 names.
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
                onCancel: () =>
                    setState(() => _managingSecondFactor = false),
                onFinished: () =>
                    setState(() => _managingSecondFactor = false),
              ),
            ),
          ),
        );
      }

      return AdminApp(
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
        title: 'BilletEnLigne — Back office',
        debugShowCheckedModeBanner: false,
        theme: KiloTheme.materialTheme(),
        home: Builder(
          builder: (context) => BackOfficeSignIn(
            client: widget.client,
            session: widget.session,
            title: context.t('admin.signIn.title'),
            t: context.t,
            onSignedIn: () =>
                setState(() => _workspace = widget.buildWorkspace()),
          ),
        ),
      ),
    );
  }
}
