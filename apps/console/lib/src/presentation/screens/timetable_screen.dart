import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// Timetables, and publishing them.
///
/// The screen the pilot was blocked on. A schedule is "the 06:00, Monday to
/// Friday, on this route, at this fare"; publishing turns it into departures a
/// traveller can actually buy.
///
/// **The RRULE is never typed.** A dispatcher picks "every day" or checks
/// weekday boxes, and this builds the canonical rule. Two reasons: nobody
/// should have to know the letters RRULE to run a coach company, and the
/// server honours a deliberate subset — a hand-typed `BYSETPOS` would be
/// refused, correctly, and the refusal would arrive as a mystery.
///
/// **Publishing reports three outcomes, not one.** Created, nothing-new, and
/// dates that could not be filled. Collapsing them into "done" hides the two
/// that need acting on: you already published this, and that coach is in the
/// workshop so those days are not on sale.
final class TimetableScreen extends StatelessWidget {
  const TimetableScreen({required this.workspace, super.key});

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
                context.t('console.timetable.title'),
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
                label: context.t('console.timetable.add'),
                fullWidth: false,
                icon: Icons.add,
                onPressed: workspace.routes.isEmpty
                    ? null
                    : () => _addSchedule(context),
                // A timetable runs on a route, so the order is forced.
                disabledHint: context.t('console.timetable.routeFirst'),
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s3),

        if (workspace.schedules.isEmpty)
          KCard(
            child: Text(
              context.t('console.timetable.empty'),
              style: kilo.text.body,
            ),
          )
        else
          for (final schedule in workspace.schedules)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: KCard(
                child: Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        schedule.departureTime,
                        style: kilo.text.amount,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(schedule.routeCode, style: kilo.text.body),
                          Text(
                            _describe(context, schedule.rrule),
                            style: kilo.text.caption.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    KMoney(schedule.fare.format()),
                    SizedBox(width: kilo.space.s3),
                    KButton(
                      label: context.t('console.timetable.publish'),
                      tone: KButtonTone.secondary,
                      fullWidth: false,
                      onPressed: () => _publish(context, schedule.id),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  /// Renders an RRULE as a sentence.
  ///
  /// The rule is stored canonically, so this parses rather than pattern-
  /// matches strings — and an unparseable one says so instead of rendering
  /// something confident and wrong.
  String _describe(BuildContext context, String rrule) {
    final parsed = Recurrence.parse(rrule);
    if (parsed case Err()) return rrule;

    final r = parsed.valueOrNull!;
    if (r.frequency == RecurrenceFrequency.daily) {
      return r.interval == 1
          ? context.t('console.timetable.everyDay')
          : context.t('console.timetable.everyNDays', {'n': r.interval});
    }

    const names = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    final days = (r.weekdays.toList()..sort())
        .map((d) => context.t('console.timetable.day.${names[d - 1]}'))
        .join(', ');
    return days;
  }

  Future<void> _publish(BuildContext context, String scheduleId) async {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);

    final weeks = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.t('console.timetable.publishTitle')),
        content: Text(dialogContext.t('console.timetable.publishBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.t('common.actions.cancel')),
          ),
          // Bounded horizons rather than a date picker. Nobody sells a coach
          // seat two years out, and the practical window is the next few
          // weeks — so the choice is two taps rather than four.
          for (final w in const [1, 4, 12])
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(w),
              child: Text(dialogContext.t('console.timetable.weeks', {'n': w})),
            ),
        ],
      ),
    );

    if (weeks == null) return;
    await workspace.materialise(
      scheduleId: scheduleId,
      from: from,
      to: from.add(Duration(days: weeks * 7)),
    );
  }

  Future<void> _addSchedule(BuildContext context) async {
    final time = TextEditingController(text: '06:00');
    final fare = TextEditingController(text: '12000');
    var routeId = workspace.routes.first.id;
    String? vehicleId = workspace.vehicles.isEmpty
        ? null
        : workspace.vehicles.first.id;
    var everyDay = true;
    final days = <int>{DateTime.monday, DateTime.friday};

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) => AlertDialog(
          title: Text(dialogContext.t('console.timetable.add')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: routeId,
                    decoration: InputDecoration(
                      labelText: dialogContext.t('console.timetable.route'),
                    ),
                    items: [
                      for (final r in workspace.routes)
                        DropdownMenuItem(value: r.id, child: Text(r.code)),
                    ],
                    onChanged: (v) => setState(() => routeId = v ?? routeId),
                  ),
                  SizedBox(height: dialogContext.kilo.space.s3),

                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: vehicleId,
                    decoration: InputDecoration(
                      labelText: dialogContext.t('console.timetable.vehicle'),
                      // Without a coach the rule still saves and publishes
                      // nothing, naming every date it skipped. Said here so
                      // that is a choice rather than a surprise.
                      helperText: dialogContext.t(
                        'console.timetable.vehicleHelp',
                      ),
                    ),
                    items: [
                      for (final v in workspace.vehicles)
                        DropdownMenuItem(
                          value: v.id,
                          child: Text('${v.registration} · ${v.capacity}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => vehicleId = v),
                  ),
                  SizedBox(height: dialogContext.kilo.space.s3),

                  Row(
                    children: [
                      Expanded(
                        child: KField(
                          label: dialogContext.t('console.timetable.time'),
                          controller: time,
                          helper: dialogContext.t('console.timetable.timeHelp'),
                        ),
                      ),
                      SizedBox(width: dialogContext.kilo.space.s3),
                      Expanded(
                        child: KField(
                          label: dialogContext.t('console.timetable.fare'),
                          controller: fare,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: dialogContext.kilo.space.s4),

                  // The RRULE, without the letters RRULE.
                  SwitchListTile(
                    value: everyDay,
                    title: Text(dialogContext.t('console.timetable.everyDay')),
                    onChanged: (v) => setState(() => everyDay = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (!everyDay)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (var d = 1; d <= 7; d++)
                          FilterChip(
                            label: Text(
                              dialogContext.t(
                                'console.timetable.day.'
                                '${const ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'][d - 1]}',
                              ),
                            ),
                            selected: days.contains(d),
                            onSelected: (on) => setState(
                              () => on ? days.add(d) : days.remove(d),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(dialogContext.t('common.actions.cancel')),
            ),
            FilledButton(
              onPressed: everyDay || days.isNotEmpty
                  ? () => Navigator.of(dialogContext).pop(true)
                  : null,
              child: Text(dialogContext.t('common.actions.save')),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final fareMinor = int.tryParse(fare.text.trim());
    if (fareMinor == null || fareMinor < 1) return;
    if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(time.text.trim())) return;

    final now = DateTime.now();
    await workspace.saveSchedule(
      routeId: routeId,
      // Built here, never typed. The server honours a subset and refuses the
      // rest by name; a hand-typed rule would meet that refusal as a mystery.
      rrule: (everyDay ? Recurrence.daily() : Recurrence.weekly(days))
          .toRRule(),
      departureTime: time.text.trim(),
      fareMinor: fareMinor,
      validFrom: DateTime(now.year, now.month, now.day),
      vehicleId: vehicleId,
    );
  }
}
