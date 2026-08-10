import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// Where this operator runs.
///
/// A route is a pair of cities and a duration — **duration, not an arrival
/// time**, because the arrival is computed per departure. A route that stored
/// arrival times would need editing every time a timetable moved, which is
/// exactly the kind of hidden coupling that makes a schedule change take an
/// afternoon.
///
/// The endpoints are picked from the cities the platform serves rather than
/// typed. A free-text city code is a route nobody can search for, and it
/// fails silently: the operator sees their route in this list and no
/// traveller ever finds it.
final class NetworkScreen extends StatelessWidget {
  const NetworkScreen({required this.workspace, super.key});

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
                context.t('console.network.title'),
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
                label: context.t('console.network.addRoute'),
                fullWidth: false,
                icon: Icons.add,
                onPressed: workspace.cities.length < 2
                    ? null
                    : () => _addRoute(context),
                disabledHint: context.t('console.network.needCities'),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s3),

        if (workspace.routes.isEmpty)
          KCard(
            child: Text(
              context.t('console.network.empty'),
              style: kilo.text.body,
            ),
          )
        else
          for (final route in workspace.routes)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: KCard(
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(route.code, style: kilo.text.code),
                    ),
                    Expanded(
                      child: Text(
                        '${_city(route.originCity)} → '
                        '${_city(route.destinationCity)}',
                        style: kilo.text.body,
                      ),
                    ),
                    Text(
                      context.t('common.units.durationHm', {
                        'hours': route.durationMinutes ~/ 60,
                        'minutes': (route.durationMinutes % 60)
                            .toString()
                            .padLeft(2, '0'),
                      }),
                      style: kilo.text.bodySm.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                    SizedBox(width: kilo.space.s3),
                    KChip(
                      context.t(
                        route.active
                            ? 'console.network.active'
                            : 'console.network.inactive',
                      ),
                      tone: route.active
                          ? KChipTone.success
                          : KChipTone.neutral,
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  String _city(String code) {
    for (final city in workspace.cities) {
      if (city.code == code) return city.name;
    }
    return code;
  }

  Future<void> _addRoute(BuildContext context) async {
    final code = TextEditingController();
    final hours = TextEditingController(text: '7');
    final minutes = TextEditingController(text: '30');
    var origin = workspace.cities.first.code;
    var destination = workspace.cities[1].code;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(dialogContext.t('console.network.addRoute')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                KField(
                  label: dialogContext.t('console.network.code'),
                  helper: dialogContext.t('console.network.codeHelp'),
                  controller: code,
                  autofocus: true,
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: origin,
                        decoration: InputDecoration(
                          labelText: dialogContext.t('console.network.from'),
                        ),
                        items: _cityItems(),
                        onChanged: (v) => setState(() => origin = v ?? origin),
                      ),
                    ),
                    SizedBox(width: dialogContext.kilo.space.s3),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: destination,
                        decoration: InputDecoration(
                          labelText: dialogContext.t('console.network.to'),
                        ),
                        items: _cityItems(),
                        onChanged: (v) =>
                            setState(() => destination = v ?? destination),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                Row(
                  children: [
                    Expanded(
                      child: KField(
                        label: dialogContext.t('console.network.hours'),
                        controller: hours,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    SizedBox(width: dialogContext.kilo.space.s3),
                    Expanded(
                      child: KField(
                        label: dialogContext.t('console.network.minutes'),
                        controller: minutes,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
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
              onPressed: origin == destination
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: Text(dialogContext.t('common.actions.save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true || code.text.trim().isEmpty) return;

    final duration =
        (int.tryParse(hours.text.trim()) ?? 0) * 60 +
        (int.tryParse(minutes.text.trim()) ?? 0);
    if (duration < 1) return;

    await workspace.saveRoute(
      code: code.text.trim().toUpperCase(),
      originCity: origin,
      destinationCity: destination,
      durationMinutes: duration,
    );
  }

  List<DropdownMenuItem<String>> _cityItems() => [
    for (final city in workspace.cities)
      DropdownMenuItem(value: city.code, child: Text(city.name)),
  ];
}
