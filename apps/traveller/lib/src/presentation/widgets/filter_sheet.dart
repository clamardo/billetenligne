import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'formatting.dart';

/// Narrowing a day's coaches down to the ones worth reading (§6.1).
///
/// Three questions, and each is one somebody actually asks at a ticket
/// window: **which company**, **what time of day**, **up to how much**. None
/// of them is a column of the database dressed up as a control — there is no
/// "amenities" list here and no free-text hour, because neither is a question
/// anybody asks standing in a queue.
///
/// **A sheet, chosen and applied.** Filtering as each control moves would
/// send four searches over a connection that struggles with one, and would
/// move the list under the thumb that is still choosing. Nothing leaves this
/// widget until the button at the bottom is pressed.
///
/// **The window is presets, not a range.** *Matin* is the question; `05:00`
/// to `12:00` is our answer to it, in the market's own hours — the server
/// reads them against the departure day's timezone, which is the one
/// calculation this codebase refuses to do outside Postgres.
///
/// Returns the refined query, or null if the traveller backed out. The query
/// comes back with **no cursor**: changing what is on a list is a new list,
/// and [SearchDeparturesQuery.refined] drops it for exactly that reason.
Future<SearchDeparturesQuery?> showFilterSheet(
  BuildContext context, {
  required SearchDeparturesQuery query,
  required Map<String, String> operators,
  required List<DepartureSummaryDto> departures,
}) => showModalBottomSheet<SearchDeparturesQuery>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => FilterSheet(
    query: query,
    operators: operators,
    departures: departures,
  ),
);

/// One of the three departure windows, in the market's local hours.
enum _Window {
  morning(5, 12, 'travel.filter.morning'),
  afternoon(12, 17, 'travel.filter.afternoon'),
  evening(17, 24, 'travel.filter.evening');

  const _Window(this.from, this.to, this.labelKey);
  final int from;
  final int to;
  final String labelKey;

  static _Window? of(int? from, int? to) {
    for (final w in values) {
      if (w.from == from && w.to == to) return w;
    }
    return null;
  }
}

final class FilterSheet extends StatefulWidget {
  const FilterSheet({
    required this.query,
    required this.operators,
    required this.departures,
    super.key,
  });

  final SearchDeparturesQuery query;

  /// Every company seen on this road and day, id to name.
  ///
  /// Accumulated by the flow rather than read off the rows on screen: once
  /// the list is filtered to one company, the rows can no longer name the
  /// others, and a filter you cannot undo from inside the sheet that set it
  /// is a trap.
  final Map<String, String> operators;

  /// What is currently on the list, for the price scale only.
  final List<DepartureSummaryDto> departures;

  @override
  State<FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<FilterSheet> {
  late String? _operatorId = widget.query.operatorId;
  late _Window? _window = _Window.of(
    widget.query.departFromHour,
    widget.query.departToHour,
  );
  late int? _ceiling = widget.query.maxFareMinor;

  /// The cheapest and dearest fare on the road, rounded outward to the step.
  ///
  /// Taken from the coaches rather than from a constant: a ceiling slider
  /// whose scale does not match this road's prices is a control where the
  /// first third does nothing.
  static const _step = 500;

  (int, int)? get _scale {
    if (widget.departures.isEmpty) return null;
    final fares = [for (final d in widget.departures) d.fare.minor]..sort();
    final low = fares.first ~/ _step * _step;
    final high = (fares.last + _step - 1) ~/ _step * _step;
    // One price on the road is not a scale, it is a fact. A slider with a
    // single stop is a control that cannot be wrong and cannot be useful.
    return high <= low ? null : (low, high);
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final scale = _scale;
    final currency = widget.departures.isEmpty
        ? Currency.xaf
        : widget.departures.first.fare.currency;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          kilo.space.s4,
          0,
          kilo.space.s4,
          kilo.space.s4,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.t('travel.filter.title'),
                style: kilo.text.h3,
              ),
              SizedBox(height: kilo.space.s4),

              if (widget.operators.length > 1) ...[
                _heading(context, context.t('travel.filter.operator')),
                Wrap(
                  spacing: kilo.space.s2,
                  children: [
                    KChoiceChip(
                      label: context.t('travel.filter.anyOperator'),
                      selected: _operatorId == null,
                      onPressed: () => setState(() => _operatorId = null),
                    ),
                    for (final entry in widget.operators.entries)
                      KChoiceChip(
                        label: entry.value,
                        selected: _operatorId == entry.key,
                        onPressed: () =>
                            setState(() => _operatorId = entry.key),
                      ),
                  ],
                ),
                SizedBox(height: kilo.space.s4),
              ],

              _heading(context, context.t('travel.filter.window')),
              Wrap(
                spacing: kilo.space.s2,
                children: [
                  KChoiceChip(
                    label: context.t('travel.filter.anyTime'),
                    selected: _window == null,
                    onPressed: () => setState(() => _window = null),
                  ),
                  for (final w in _Window.values)
                    KChoiceChip(
                      label: context.t(w.labelKey),
                      selected: _window == w,
                      onPressed: () => setState(() => _window = w),
                    ),
                ],
              ),

              if (scale != null) ...[
                SizedBox(height: kilo.space.s4),
                _heading(context, context.t('travel.filter.price')),
                Text(
                  _ceiling == null
                      ? context.t('travel.filter.anyPrice')
                      : context.t('travel.filter.upTo', {
                          'amount': Format.money(
                            Money(_ceiling!, currency),
                            locale: locale,
                          ),
                        }),
                  style: kilo.text.body,
                ),
                Slider(
                  value: (_ceiling ?? scale.$2).clamp(scale.$1, scale.$2)
                      .toDouble(),
                  min: scale.$1.toDouble(),
                  max: scale.$2.toDouble(),
                  divisions: (scale.$2 - scale.$1) ~/ _step,
                  label: Format.money(
                    Money(_ceiling ?? scale.$2, currency),
                    locale: locale,
                  ),
                  onChanged: (value) => setState(() {
                    // At the top of the scale there is no ceiling at all,
                    // rather than one set to the dearest coach: the two are
                    // the same list today and stop being the same list the
                    // moment a page of dearer coaches loads behind it.
                    final minor = value.round();
                    _ceiling = minor >= scale.$2 ? null : minor;
                  }),
                ),
              ],

              SizedBox(height: kilo.space.s4),
              KButton(
                label: context.t('travel.filter.apply'),
                onPressed: () => Navigator.of(context).pop(
                  widget.query.refined(
                    operatorId: _operatorId,
                    clearOperator: _operatorId == null,
                    departFromHour: _window?.from,
                    departToHour: _window?.to,
                    clearWindow: _window == null,
                    maxFareMinor: _ceiling,
                    clearCeiling: _ceiling == null,
                  ),
                ),
              ),
              SizedBox(height: kilo.space.s2),
              KButton(
                label: context.t('travel.filter.clear'),
                tone: KButtonTone.ghost,
                onPressed: () => Navigator.of(context).pop(
                  widget.query.refined(
                    clearOperator: true,
                    clearWindow: true,
                    clearCeiling: true,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String text) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s2),
      child: Text(
        text,
        style: kilo.text.label.copyWith(color: kilo.color.contentSecondary),
      ),
    );
  }
}
