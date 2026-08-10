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
    super.key,
  });

  final ConsoleWorkspace workspace;
  final Widget child;

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
            onDestinationSelected: (i) =>
                workspace.openSection(sections[i]),
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
  ];

  static IconData _icon(ConsoleSection s) => switch (s) {
    ConsoleSection.today => Icons.today,
    ConsoleSection.counter => Icons.point_of_sale,
    ConsoleSection.fleet => Icons.directions_bus,
    ConsoleSection.network => Icons.alt_route,
    ConsoleSection.timetable => Icons.schedule,
  };

  static String _labelKey(ConsoleSection s) => switch (s) {
    ConsoleSection.today => 'console.nav.today',
    ConsoleSection.counter => 'console.nav.counter',
    ConsoleSection.fleet => 'console.nav.fleet',
    ConsoleSection.network => 'console.nav.network',
    ConsoleSection.timetable => 'console.nav.timetable',
  };

  /// Notices travel as `key|arg|arg`, so the *workspace* never holds prose.
  ///
  /// The same rule the server follows (ADR-0008): the layer that knows what
  /// happened emits a key and parameters, and the layer that knows the reader
  /// renders the sentence.
  static String _notice(BuildContext context, String encoded) {
    final parts = encoded.split('|');
    final key = 'console.notice.${parts.first}';
    return context.t(key, {
      for (var i = 1; i < parts.length; i++) 'a$i': parts[i],
    });
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
