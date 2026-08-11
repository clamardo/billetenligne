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
        // ── The yards ────────────────────────────────────────────────────
        //
        // On the same screen as the roads, because they are the same
        // decision: a company that opens a line to Dolisie has to say which
        // gate it leaves from before the first ticket is printed. Grouped by
        // city, because that is the only grouping anybody uses — "our two
        // Brazzaville terminals" is a sentence operators say out loud.
        SizedBox(height: kilo.space.s5),
        Row(
          children: [
            Expanded(
              child: Text(
                context.t('console.network.stations'),
                style: kilo.text.h2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: KButton(
                label: context.t('console.network.addStation'),
                fullWidth: false,
                icon: Icons.add,
                onPressed: workspace.cities.isEmpty
                    ? null
                    : () => _addStation(context),
                disabledHint: context.t('console.network.needCities'),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('console.network.stationsHelp'),
          style: kilo.text.bodySm.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s3),

        if (workspace.stations.isEmpty)
          KCard(
            child: Text(
              context.t('console.network.noStations'),
              style: kilo.text.body,
            ),
          )
        else
          for (final station in workspace.stations)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: KCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        _city(station.cityCode ?? ''),
                        style: kilo.text.bodySm.copyWith(
                          color: kilo.color.contentSecondary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(station.name, style: kilo.text.body),
                          if (station.boardingNotes != null) ...[
                            SizedBox(height: kilo.space.s1),
                            Text(
                              station.boardingNotes!,
                              style: kilo.text.bodySm.copyWith(
                                color: kilo.color.contentSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    SizedBox(width: kilo.space.s3),
                    // A closed yard stays in the list and says so. Deleting
                    // it would erase where last month's passengers were told
                    // to stand.
                    KChip(
                      context.t(
                        station.active
                            ? 'console.network.open'
                            : 'console.network.closed',
                      ),
                      tone: station.active
                          ? KChipTone.success
                          : KChipTone.neutral,
                    ),
                    IconButton(
                      icon: Icon(
                        station.active
                            ? Icons.do_not_disturb_on_outlined
                            : Icons.check_circle_outline,
                      ),
                      tooltip: context.t(
                        station.active
                            ? 'console.network.close'
                            : 'console.network.reopen',
                      ),
                      onPressed: () => workspace.saveStation(
                        id: station.id,
                        cityCode: station.cityCode ?? '',
                        name: station.name,
                        boardingNotes: station.boardingNotes,
                        active: !station.active,
                      ),
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

  /// Opening a yard: a city, a name, and how to find it.
  ///
  /// The directions field is the point of the dialog. A name alone —
  /// "Gare de Mikalou" — is what a company already tells people on the
  /// telephone, and it is exactly what somebody standing on the wrong side of
  /// the road cannot use.
  Future<void> _addStation(BuildContext context) async {
    final name = TextEditingController();
    final notes = TextEditingController();
    var city = workspace.cities.first.code;

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(dialogContext.t('console.network.addStation')),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: city,
                  decoration: InputDecoration(
                    labelText: dialogContext.t('console.network.city'),
                  ),
                  items: _cityItems(),
                  onChanged: (value) => setState(() => city = value ?? city),
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                KField(
                  label: dialogContext.t('console.network.stationName'),
                  controller: name,
                  hint: dialogContext.t('console.network.stationNameHint'),
                ),
                SizedBox(height: dialogContext.kilo.space.s3),
                KField(
                  label: dialogContext.t('console.network.boardingNotes'),
                  controller: notes,
                  hint: dialogContext.t('console.network.boardingNotesHint'),
                  maxLines: 3,
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

    await workspace.saveStation(
      cityCode: city,
      name: name.text.trim(),
      boardingNotes: notes.text.trim().isEmpty ? null : notes.text.trim(),
    );
  }

  List<DropdownMenuItem<String>> _cityItems() => [
    for (final city in workspace.cities)
      DropdownMenuItem(value: city.code, child: Text(city.name)),
  ];
}
