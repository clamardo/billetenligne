import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';
import 'layout_builder_screen.dart';

/// Layouts and coaches.
///
/// The screen that makes a fleet of fourteen a twenty-minute setup rather
/// than a two-hour one (`06-fleet-and-routes.md` §1). A layout is drawn once
/// and pointed at by every identical coach; the seat map an operator checks
/// here is the one every one of those coaches sells.
///
/// **Presets are the default path; the builder is the way out of it.** Four
/// presets cover what actually runs in Congo and picking one takes ninety
/// seconds, so they stay the first control. The section builder sits beside
/// them for the coach that matches none — a 2+3 with a five-across rear
/// bench, an aircraft with a first cabin — and it is a screen rather than a
/// dialog because drawing one honestly takes twenty minutes.
final class FleetScreen extends StatelessWidget {
  const FleetScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.t('console.fleet.layouts'),
                style: kilo.text.h2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // A bounded width, because `disabledHint` renders the button and
            // its explanation as a Column — and a Column in a Row with no
            // constraint is an infinite width, which is a layout crash
            // rather than a squashed button.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: KButton(
                label: context.t('console.fleet.addLayout'),
                fullWidth: false,
                icon: Icons.add,
                onPressed: () => _addLayout(context),
              ),
            ),
            SizedBox(width: kilo.space.s2),
            // Secondary, and next to the presets rather than behind them: an
            // operator who needs it needs it on their first afternoon, and an
            // operator who does not should not wonder what they are missing.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: KButton(
                label: context.t('console.fleet.builder.open'),
                fullWidth: false,
                tone: KButtonTone.secondary,
                icon: Icons.grid_on,
                onPressed: () => _drawLayout(context),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s3),

        if (workspace.layouts.isEmpty)
          KCard(
            child: Text(
              context.t('console.fleet.noLayouts'),
              style: kilo.text.body,
            ),
          )
        else
          for (final layout in workspace.layouts)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: KCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(layout.displayName, style: kilo.text.body),
                          Text(
                            context.t('console.fleet.layoutSummary', {
                              'capacity': layout.capacity,
                              'vehicles': layout.vehicleCount,
                            }),
                            style: kilo.text.caption.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    KChip(layout.mode),
                  ],
                ),
              ),
            ),

        SizedBox(height: kilo.space.s6),

        Row(
          children: [
            Expanded(
              child: Text(
                context.t('console.fleet.vehicles'),
                style: kilo.text.h2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // A bounded width, because `disabledHint` renders the button and
            // its explanation as a Column — and a Column in a Row with no
            // constraint is an infinite width, which is a layout crash
            // rather than a squashed button.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: KButton(
                label: context.t('console.fleet.addVehicle'),
                fullWidth: false,
                icon: Icons.add,
                onPressed: workspace.layouts.isEmpty
                    ? null
                    : () => _addVehicle(context),
                // A coach has to point at a layout, so the order is forced. A
                // greyed control with no explanation is the most common way an
                // app strands somebody.
                disabledHint: context.t('console.fleet.layoutFirst'),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s3),

        for (final vehicle in workspace.vehicles)
          Padding(
            padding: EdgeInsets.only(bottom: kilo.space.s2),
            child: KCard(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          vehicle.nickname == null
                              ? vehicle.registration
                              : '${vehicle.registration} · ${vehicle.nickname}',
                          style: kilo.text.body,
                        ),
                        Text(
                          '${vehicle.layoutName} · ${vehicle.capacity}',
                          style: kilo.text.caption.copyWith(
                            color: kilo.color.contentSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  KChip(
                    context.t('console.fleet.status.${vehicle.status}'),
                    tone: vehicle.sellable
                        ? KChipTone.success
                        : KChipTone.warning,
                  ),
                  SizedBox(width: kilo.space.s3),
                  _StatusMenu(vehicle: vehicle, workspace: workspace),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _addLayout(BuildContext context) async {
    final name = TextEditingController();
    final rows = TextEditingController();
    var preset = 'bus_standard_49';

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(dialogContext.t('console.fleet.addLayout')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                KField(
                  label: dialogContext.t('console.fleet.layoutName'),
                  controller: name,
                  autofocus: true,
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: preset,
                  decoration: InputDecoration(
                    labelText: dialogContext.t('console.fleet.preset'),
                  ),
                  items: [
                    for (final p in const [
                      'bus_standard_49',
                      'bus_vip_front',
                      'air_two_class',
                    ])
                      DropdownMenuItem(
                        value: p,
                        child: Text(
                          dialogContext.t('console.fleet.presets.$p'),
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => preset = v ?? preset),
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                KField(
                  label: dialogContext.t('console.fleet.rowsOptional'),
                  // The one thing an operator almost always adjusts: a preset
                  // is a 49-seater and theirs is a 51.
                  helper: dialogContext.t('console.fleet.rowsHelp'),
                  controller: rows,
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.t('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.t('common.actions.save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true || name.text.trim().isEmpty) return;
    await workspace.saveLayout(
      name: name.text.trim(),
      preset: preset,
      rows: int.tryParse(rows.text.trim()),
    );
  }

  /// Opens the builder, and saves whatever comes back.
  ///
  /// The screen returns a [LayoutDraft] or nothing — it does no saving of its
  /// own, so the one place that talks to the workspace is still this one, and
  /// a cancelled draw is indistinguishable from never having opened it.
  Future<void> _drawLayout(BuildContext context) async {
    final draft = await Navigator.of(context).push<LayoutDraft>(
      MaterialPageRoute(builder: (_) => const LayoutBuilderScreen()),
    );
    if (draft == null) return;
    await workspace.drawLayout(draft);
  }

  Future<void> _addVehicle(BuildContext context) async {
    final registration = TextEditingController();
    final nickname = TextEditingController();
    var layoutId = workspace.layouts.first.id;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(dialogContext.t('console.fleet.addVehicle')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                KField(
                  label: dialogContext.t('console.fleet.registration'),
                  controller: registration,
                  autofocus: true,
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                KField(
                  label: dialogContext.t('console.fleet.nicknameOptional'),
                  helper: dialogContext.t('console.fleet.nicknameHelp'),
                  controller: nickname,
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: layoutId,
                  decoration: InputDecoration(
                    labelText: dialogContext.t('console.fleet.layout'),
                  ),
                  items: [
                    for (final l in workspace.layouts)
                      DropdownMenuItem(
                        value: l.id,
                        child: Text('${l.displayName} · ${l.capacity}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => layoutId = v ?? layoutId),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.t('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.t('common.actions.save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true || registration.text.trim().isEmpty) return;
    await workspace.saveVehicle(
      registration: registration.text.trim().toUpperCase(),
      layoutId: layoutId,
      nickname: nickname.text.trim().isEmpty ? null : nickname.text.trim(),
    );
  }
}

class _StatusMenu extends StatelessWidget {
  const _StatusMenu({required this.vehicle, required this.workspace});

  final VehicleDto vehicle;
  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: context.t('console.fleet.changeStatus'),
    onSelected: (status) =>
        workspace.setVehicleStatus(vehicleId: vehicle.id, status: status),
    itemBuilder: (context) => [
      for (final status in const [
        'active',
        'maintenance',
        'out_of_service',
        'blocked_compliance',
      ])
        PopupMenuItem(
          value: status,
          child: Text(context.t('console.fleet.status.$status')),
        ),
    ],
  );
}
