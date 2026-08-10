import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';

/// The frame every back-office screen sits in.
///
/// A navigation rail, like the console's, because this is a desktop product
/// worked in long sittings. Two things are different, and both are the point
/// of the surface:
///
///   * **The reason field is in the frame, not in a dialog.** It is required
///     on every write and recorded on every read (ADR-0011). A field that
///     appears at the moment of confirming teaches people to type "review" to
///     get past it; a field that is visibly attached to the whole session is
///     one somebody fills in once, honestly, and can see while they work.
///   * **The rail is built from capabilities.** A `viewer` has no payment
///     queue at all — not a greyed one, which invites a support call, and not
///     a visible one that 403s, which teaches people our buttons lie.
final class AdminShell extends StatefulWidget {
  const AdminShell({
    required this.workspace,
    required this.child,
    super.key,
  });

  final AdminWorkspace workspace;
  final Widget child;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  late final _reason = TextEditingController(text: widget.workspace.reason);

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final workspace = widget.workspace;
    final sections = _visibleSections(workspace);

    // A `viewer` holds `booking.read` and `finance.read` and neither of the
    // two capabilities this app is built from. They are not shown an empty
    // rail — Flutter would assert on one, and an app with no destinations is
    // a worse answer than a sentence saying so.
    if (sections.isEmpty) {
      return Scaffold(
        body: KStateView(
          KEmpty(
            title: context.t('admin.noAccess.title'),
            body: context.t('admin.noAccess.body'),
          ),
        ),
      );
    }

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
                  Icon(Icons.shield_outlined, color: kilo.color.brandPrimary),
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
                _ReasonBar(workspace: workspace, controller: _reason),
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
                Expanded(child: widget.child),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Only the sections this person can actually use.
  static List<AdminSection> _visibleSections(AdminWorkspace w) => [
    if (w.can('platform.operator.review')) AdminSection.queue,
    if (w.can('platform.operator.review')) AdminSection.operators,
    if (w.can('platform.payment.reconcile')) AdminSection.payments,
  ];

  static IconData _icon(AdminSection s) => switch (s) {
    AdminSection.queue => Icons.inbox,
    AdminSection.operators => Icons.apartment,
    AdminSection.payments => Icons.help_outline,
  };

  static String _labelKey(AdminSection s) => switch (s) {
    AdminSection.queue => 'admin.nav.queue',
    AdminSection.operators => 'admin.nav.operators',
    AdminSection.payments => 'admin.nav.payments',
  };

  /// Notices travel as `key|arg|arg`, so the *workspace* never holds prose.
  static String _notice(BuildContext context, String encoded) {
    final parts = encoded.split('|');
    return context.t('admin.notice.${parts.first}', {
      for (var i = 1; i < parts.length; i++) 'a$i': parts[i],
    });
  }
}

/// The one field that is always on screen.
class _ReasonBar extends StatelessWidget {
  const _ReasonBar({required this.workspace, required this.controller});

  final AdminWorkspace workspace;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final identity = workspace.identity;

    return Container(
      color: kilo.color.surfaceRaised,
      padding: EdgeInsets.symmetric(
        horizontal: kilo.space.s4,
        vertical: kilo.space.s3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: workspace.setReason,
              style: kilo.text.body,
              decoration: InputDecoration(
                isDense: true,
                labelText: context.t('admin.reason.label'),
                hintText: context.t('admin.reason.hint'),
                helperText: context.t('admin.reason.help'),
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.edit_note),
              ),
            ),
          ),
          SizedBox(width: kilo.space.s4),
          if (identity != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  identity.fullName ?? identity.email ?? identity.userId,
                  style: kilo.text.label,
                ),
                Text(
                  identity.role,
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
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
