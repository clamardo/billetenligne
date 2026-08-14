import 'dart:async';

import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';

import '../application/admin_workspace.dart';
import 'l10n.dart';
import 'screens/compliance_screen.dart';
import 'screens/funnel_screen.dart';
import 'screens/operator_screen.dart';
import 'screens/payments_screen.dart';
import 'screens/payouts_screen.dart';
import 'screens/queue_screen.dart';
import 'widgets/admin_shell.dart';

/// The back office.
///
/// Flutter web, sharing `bel_design`, `bel_client` and the translation
/// catalog with the traveller app and the console. Three surfaces, one design
/// system, one wire format — which is the ADR-0004 bet, and the reason this
/// app is a few screens rather than a project.
final class AdminApp extends StatelessWidget {
  const AdminApp({
    required this.catalog,
    required this.workspace,
    this.language = 'fr',
    this.onManageSecondFactor,
    this.mode,
    super.key,
  });

  final TranslationCatalog catalog;
  final AdminWorkspace workspace;
  final String language;

  /// Opens the authenticator screen. Null in tests and in any composition
  /// that has no client to enrol against — the shell omits the entry rather
  /// than showing one that does nothing.
  final VoidCallback? onManageSecondFactor;

  /// The theme choice, held outside the widget tree so it survives a rebuild
  /// and can be written to disk by whoever composed the app. Absent in tests
  /// — following the platform is a correct default, not a fallback.
  final KiloModeController? mode;

  @override
  Widget build(BuildContext context) => Localized(
    catalog: catalog,
    initialLanguage: language,
    child: KiloModeScope(
      notifier: mode ?? _fallback,
      child: ListenableBuilder(
        listenable: mode ?? _fallback,
        builder: (context, _) => MaterialApp(
          title: 'BilletEnLigne — Back office',
          debugShowCheckedModeBanner: false,
          theme: KiloTheme.materialTheme(),
          darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
          themeMode: (mode ?? _fallback).mode.materialMode,
          home: _Admin(
            workspace: workspace,
            onManageSecondFactor: onManageSecondFactor,
          ),
        ),
      ),
    ),
  );
}

/// For the surfaces and the tests that wire no persistence: an in-memory
/// choice that starts at *follow the platform*, so the toggle still works for
/// the length of a session rather than being absent or inert.
final _fallback = KiloModeController();

class _Admin extends StatefulWidget {
  const _Admin({required this.workspace, this.onManageSecondFactor});
  final AdminWorkspace workspace;
  final VoidCallback? onManageSecondFactor;

  @override
  State<_Admin> createState() => _AdminState();
}

class _AdminState extends State<_Admin> {
  StreamSubscription<void>? _subscription;

  AdminWorkspace get _work => widget.workspace;

  @override
  void initState() {
    super.initState();
    _subscription = _work.changes.listen((_) {
      if (mounted) setState(() {});
    });
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

    final open = _work.openOperator;

    return AdminShell(
      workspace: _work,
      onManageSecondFactor: widget.onManageSecondFactor,
      // An operator's file renders *over* whichever list it was opened from,
      // rather than as a fourth section. It is a step into a row, and a
      // navigation rail that changes under somebody who drilled into
      // something is a rail that loses their place.
      child: open != null
          ? OperatorScreen(workspace: _work, detail: open)
          : switch (_work.section) {
              AdminSection.queue => QueueScreen(workspace: _work),
              AdminSection.operators => QueueScreen(
                workspace: _work,
                showFilters: true,
              ),
              AdminSection.compliance => ComplianceScreen(workspace: _work),
              AdminSection.payments => PaymentsScreen(workspace: _work),
              AdminSection.payouts => PayoutsScreen(workspace: _work),
              AdminSection.funnel => FunnelScreen(workspace: _work),
            },
    );
  }
}
