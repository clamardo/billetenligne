import 'dart:async';

import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/console_workspace.dart';
import 'l10n.dart';
import 'screens/counter_screen.dart';
import 'screens/fleet_screen.dart';
import 'screens/network_screen.dart';
import 'screens/timetable_screen.dart';
import 'screens/today_screen.dart';
import 'screens/policies_screen.dart';
import 'screens/protection_screen.dart';
import 'screens/statements_screen.dart';
import 'screens/vitrine_screen.dart';
import 'widgets/console_shell.dart';

/// The operator console.
///
/// Flutter web, because an agency has a laptop or a tablet and neither of
/// them wants an install — and because the console's screens are tables and
/// forms, which is the one thing the web is unambiguously good at.
///
/// It shares `bel_design`, `bel_client` and the translation catalog with the
/// traveller app. That is the ADR-0004 bet paying off: the seat map a vendor
/// sells from is the same widget the traveller bought on, so the two cannot
/// drift into disagreeing about which seat is 12A.
final class ConsoleApp extends StatelessWidget {
  const ConsoleApp({
    required this.catalog,
    required this.workspace,
    this.language = 'fr',
    this.onManageSecondFactor,
    super.key,
  });

  final TranslationCatalog catalog;
  final ConsoleWorkspace workspace;
  final String language;

  /// Opens the authenticator screen. Null in tests and in any composition
  /// that has no client to enrol against — the shell simply omits the entry
  /// rather than showing one that does nothing.
  final VoidCallback? onManageSecondFactor;

  @override
  Widget build(BuildContext context) => Localized(
    catalog: catalog,
    initialLanguage: language,
    child: MaterialApp(
      title: 'BilletEnLigne — Console',
      debugShowCheckedModeBanner: false,
      theme: KiloTheme.materialTheme(),
      darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
      home: _Console(
        workspace: workspace,
        onManageSecondFactor: onManageSecondFactor,
      ),
    ),
  );
}

class _Console extends StatefulWidget {
  const _Console({required this.workspace, this.onManageSecondFactor});
  final ConsoleWorkspace workspace;
  final VoidCallback? onManageSecondFactor;

  @override
  State<_Console> createState() => _ConsoleState();
}

class _ConsoleState extends State<_Console> {
  StreamSubscription<void>? _subscription;

  ConsoleWorkspace get _work => widget.workspace;

  @override
  void initState() {
    super.initState();
    _subscription = _work.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // Identity first: the navigation is drawn from capabilities, so rendering
    // before we know them would show a vendor a Fleet tab for one frame.
    unawaited(_work.start());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_work.identity == null) {
      return Scaffold(
        body: KStateView(
          _work.failure == null
              ? KLoading(context.t('common.state.loading'))
              : KFailed(
                  title: context.t('common.state.errorTitle'),
                  body: context.t(_work.failure!.messageKey),
                  retryLabel: context.t('common.actions.retry'),
                  onRetry: _work.start,
                  traceId: _work.failure?.traceId,
                ),
        ),
      );
    }

    return ConsoleShell(
      workspace: _work,
      onManageSecondFactor: widget.onManageSecondFactor,
      child: switch (_work.section) {
        ConsoleSection.today => TodayScreen(workspace: _work),
        ConsoleSection.counter => CounterScreen(workspace: _work),
        ConsoleSection.fleet => FleetScreen(workspace: _work),
        ConsoleSection.network => NetworkScreen(workspace: _work),
        ConsoleSection.timetable => TimetableScreen(workspace: _work),
        ConsoleSection.policies => PoliciesScreen(workspace: _work),
        ConsoleSection.vitrine => VitrineScreen(workspace: _work),
        ConsoleSection.finance => StatementsScreen(workspace: _work),
        ConsoleSection.protection => ProtectionScreen(workspace: _work),
      },
    );
  }
}
