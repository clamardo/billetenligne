import 'package:bel_design/bel_design.dart';
import 'package:bel_client/bel_client.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// The frame every console screen sits in.
///
/// A navigation rail rather than a drawer: the console is a desktop and
/// tablet product, and a vendor moving between the till and today's
/// departures forty times a shift should not open a menu each time.
///
/// **The rail is built from capabilities, not roles** (ADR-0011). A vendor
/// has no Fleet tab at all — not a greyed one, which invites a support call,
/// and not a visible one that 403s, which teaches people our buttons lie.
final class ConsoleShell extends StatelessWidget {
  const ConsoleShell({
    required this.workspace,
    required this.child,
    this.onManageSecondFactor,
    super.key,
  });

  final ConsoleWorkspace workspace;
  final Widget child;

  /// Somebody who replaced a phone has to be able to move their
  /// authenticator, and the only alternative to a button here is a support
  /// call — which is the cost this whole control was meant to avoid.
  final VoidCallback? onManageSecondFactor;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final sections = _visibleSections(workspace);
    final index = sections.indexOf(workspace.section);

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index < 0 ? 0 : index,
            onDestinationSelected: (i) => workspace.openSection(sections[i]),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: EdgeInsets.symmetric(vertical: kilo.space.s4),
              child: Column(
                children: [
                  Icon(Icons.directions_bus, color: kilo.color.brandPrimary),
                  SizedBox(height: kilo.space.s2),
                  Text('BEL', style: kilo.text.label),
                ],
              ),
            ),
            destinations: [
              for (final section in sections)
                NavigationRailDestination(
                  icon: Icon(_icon(section)),
                  label: Text(context.t(_labelKey(section))),
                ),
            ],
            trailing: onManageSecondFactor == null
                ? null
                : Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: kilo.space.s4),
                        child: IconButton(
                          icon: const Icon(Icons.lock_outline),
                          tooltip: context.t('auth.enrol.manage'),
                          onPressed: onManageSecondFactor,
                        ),
                      ),
                    ),
                  ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                // A thin bar rather than a dialog. Every one of these is
                // information about work that already finished; interrupting
                // somebody to acknowledge a success is how a till gets slow.
                if (workspace.busy) const LinearProgressIndicator(minHeight: 2),
                if (workspace.notice != null)
                  _Banner(
                    text: _notice(context, workspace.notice!),
                    tone: kilo.color.successSoft,
                    foreground: kilo.color.success,
                  ),
                if (workspace.failure != null)
                  _Banner(
                    text: context.t(
                      workspace.failure!.messageKey,
                      workspace.failure is ServerRefused
                          ? (workspace.failure! as ServerRefused).params
                          : const {},
                    ),
                    tone: kilo.color.dangerSoft,
                    foreground: kilo.color.danger,
                    // The one string a support agent needs, and it is
                    // worthless if the screen throws it away.
                    traceId: workspace.failure?.traceId,
                  ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Only the sections this person can actually use.
  static List<ConsoleSection> _visibleSections(ConsoleWorkspace w) => [
    ConsoleSection.today,
    if (w.can('booking.sell')) ConsoleSection.counter,
    if (w.can('fleet.manage')) ConsoleSection.fleet,
    if (w.can('route.manage')) ConsoleSection.network,
    if (w.can('departure.manage')) ConsoleSection.timetable,
    if (w.can('booking.read')) ConsoleSection.policies,
    if (w.can('vitrine.manage')) ConsoleSection.vitrine,
    // The owner and the finance role. A vendor does not need to see what the
    // company was paid last week, and a tab they cannot use is a tab they
    // eventually ask about.
    if (w.can('finance.read')) ConsoleSection.finance,
    // Reading needs only `booking.read`: a dispatcher has to know option ③
    // exists before a breakdown, not after. Writing needs `protection.manage`,
    // which the screen checks separately.
    if (w.can('booking.read')) ConsoleSection.protection,
  ];

  static IconData _icon(ConsoleSection s) => switch (s) {
    ConsoleSection.today => Icons.today,
    ConsoleSection.counter => Icons.point_of_sale,
    ConsoleSection.fleet => Icons.directions_bus,
    ConsoleSection.network => Icons.alt_route,
    ConsoleSection.timetable => Icons.schedule,
    ConsoleSection.policies => Icons.gavel,
    ConsoleSection.vitrine => Icons.storefront,
    ConsoleSection.finance => Icons.receipt_long,
    ConsoleSection.protection => Icons.handshake,
  };

  static String _labelKey(ConsoleSection s) => switch (s) {
    ConsoleSection.today => 'console.nav.today',
    ConsoleSection.counter => 'console.nav.counter',
    ConsoleSection.fleet => 'console.nav.fleet',
    ConsoleSection.network => 'console.nav.network',
    ConsoleSection.timetable => 'console.nav.timetable',
    ConsoleSection.policies => 'console.nav.policies',
    ConsoleSection.vitrine => 'console.nav.vitrine',
    ConsoleSection.finance => 'console.nav.finance',
    ConsoleSection.protection => 'console.nav.protection',
  };

  /// Notices travel as `key|arg|arg`, so the *workspace* never holds prose.
  ///
  /// The same rule the server follows (ADR-0008): the layer that knows what
  /// happened emits a key and parameters, and the layer that knows the reader
  /// renders the sentence.
  static String _notice(BuildContext context, String encoded) {
    return context.tEncoded(encoded, prefix: 'console.notice.');
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.tone,
    required this.foreground,
    this.traceId,
  });

  final String text;
  final Color tone;
  final Color foreground;
  final String? traceId;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Container(
      width: double.infinity,
      color: tone,
      padding: EdgeInsets.symmetric(
        horizontal: kilo.space.s4,
        vertical: kilo.space.s3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: kilo.text.body.copyWith(color: foreground),
            ),
          ),
          if (traceId != null)
            SelectableText(
              traceId!,
              style: kilo.text.code.copyWith(color: foreground),
            ),
        ],
      ),
    );
  }
}
