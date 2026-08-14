import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// One city, as the picker needs it.
final class CityOption {
  const CityOption(this.code, this.name);
  final String code;
  final String name;
}

/// Where are you going, and when.
///
/// Three fields and one button. The temptation on this screen is to add
/// filters, sorting and a fare calendar; the traveller has a route and a day,
/// and every additional control is a thing between them and a seat.
///
/// The date defaults to **tomorrow**, not today. Intercity coaches leave in
/// the early morning and almost nobody books the 06:00 at 05:40 — defaulting
/// to today shows an empty list to most people who open the app in the
/// afternoon.
final class SearchScreen extends StatefulWidget {
  const SearchScreen({
    required this.cities,
    required this.onSearch,
    this.initialQuery,
    this.onOpenTickets,
    super.key,
  });

  final List<CityOption> cities;
  final void Function(SearchDeparturesQuery query) onSearch;
  final SearchDeparturesQuery? initialQuery;

  /// The way to a ticket already bought. On this screen rather than behind a
  /// tab bar because a returning traveller opens the app for exactly two
  /// reasons — to buy a seat, or to show one they already own — and the
  /// second must not cost a search.
  final VoidCallback? onOpenTickets;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late String? _from = widget.initialQuery?.originCity ?? _firstCity;
  late String? _to = widget.initialQuery?.destinationCity;
  late DateTime _date =
      widget.initialQuery?.date ??
      DateTime.now().toUtc().add(const Duration(days: 1));
  late int _passengers = widget.initialQuery?.passengers ?? 1;

  String? get _firstCity =>
      widget.cities.isEmpty ? null : widget.cities.first.code;

  bool get _valid => _from != null && _to != null && _from != _to;

  void _swap() => setState(() {
    final was = _from;
    _from = _to;
    _to = was;
  });

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final today = DateTime.now().toUtc();
    final tomorrow = today.add(const Duration(days: 1));

    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _Hero(onOpenTickets: widget.onOpenTickets),
          Padding(
            padding: EdgeInsets.fromLTRB(
              kilo.space.s4,
              kilo.space.s5,
              kilo.space.s4,
              kilo.space.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _CityPicker(
                        label: context.t('common.labels.from'),
                        hint: context.t('travel.search.chooseOrigin'),
                        cities: widget.cities,
                        value: _from,
                        onChanged: (v) => setState(() => _from = v),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: kilo.space.s2),
                      child: Semantics(
                        button: true,
                        label: context.t('travel.search.swap'),
                        child: IconButton(
                          onPressed: _swap,
                          icon: const Icon(Icons.swap_horiz),
                          color: kilo.color.brandPrimary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _CityPicker(
                        label: context.t('common.labels.to'),
                        hint: context.t('travel.search.chooseDestination'),
                        cities: widget.cities,
                        value: _to,
                        onChanged: (v) => setState(() => _to = v),
                      ),
                    ),
                  ],
                ),

                if (_from != null && _from == _to) ...[
                  SizedBox(height: kilo.space.s2),
                  Text(
                    context.t('travel.search.sameCity'),
                    style: kilo.text.bodySm.copyWith(color: kilo.color.danger),
                  ),
                ],

                SizedBox(height: kilo.space.s5),
                Text(
                  context.t('common.labels.date'),
                  style: kilo.text.label.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
                SizedBox(height: kilo.space.s2),
                // A wrap rather than a row: three choices, two of them
                // whole words, do not fit across a 320 dp handset — which is
                // the handset ADR-0002 names as the target, not the edge
                // case. The third drops to a second line rather than being
                // squeezed to nothing.
                Wrap(
                  spacing: kilo.space.s2,
                  runSpacing: kilo.space.s2,
                  children: [
                    _DateChoice(
                      label: context.t('travel.search.today'),
                      selected: _isSameDay(_date, today),
                      onTap: () => setState(() => _date = today),
                    ),
                    _DateChoice(
                      label: context.t('travel.search.tomorrow'),
                      selected: _isSameDay(_date, tomorrow),
                      onTap: () => setState(() => _date = tomorrow),
                    ),
                    _DateChoice(
                      label:
                          _isSameDay(_date, today) ||
                              _isSameDay(_date, tomorrow)
                          ? context.t('travel.search.pickDate')
                          : Format.shortDate(_date, locale: context.language),
                      selected:
                          !_isSameDay(_date, today) &&
                          !_isSameDay(_date, tomorrow),
                      onTap: _pickDate,
                    ),
                  ],
                ),

                SizedBox(height: kilo.space.s5),
                Text(
                  context.t('common.labels.passengers'),
                  style: kilo.text.label.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
                SizedBox(height: kilo.space.s2),
                _PassengerStepper(
                  value: _passengers,
                  onChanged: (v) => setState(() => _passengers = v),
                ),

                SizedBox(height: kilo.space.s8),
                KButton(
                  label: context.t('travel.search.submit'),
                  icon: Icons.search,
                  onPressed: _valid
                      ? () => widget.onSearch(
                          SearchDeparturesQuery(
                            originCity: _from!,
                            destinationCity: _to!,
                            date: _date,
                            passengers: _passengers,
                          ),
                        )
                      : null,
                  // A greyed button with no explanation is the most common way an
                  // app strands somebody.
                  // Its own sentence rather than the picker's placeholder. The
                  // button is explaining what is missing overall, which is not the
                  // same thing as labelling one empty field.
                  disabledHint: _from == null || _to == null
                      ? context.t('travel.search.chooseBoth')
                      : context.t('travel.search.sameCity'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(now) ? now : _date,
      firstDate: now,
      // A year out. Beyond that is a typo, and the server refuses it anyway.
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// The full-bleed opening of the app.
///
/// This screen used to begin with a line of black text on white, which is an
/// accurate description of what the product does and tells somebody nothing
/// about whether it is worth trusting with money. The drawing is painted from
/// theme tokens rather than loaded, so it costs no request, cannot fail to
/// arrive on 2G, and recolours itself in dark mode.
class _Hero extends StatelessWidget {
  const _Hero({this.onOpenTickets});

  final VoidCallback? onOpenTickets;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    // Tall enough to be a picture rather than a band, short enough that the
    // first field is still on screen on a 5-inch handset.
    final height = MediaQuery.sizeOf(context).height < 700 ? 190.0 : 232.0;

    return KScene(
      KSceneArt.journey,
      height: height,
      child: SafeArea(
        bottom: false,
        // A stack rather than a column with a spacer: the artwork is a fixed
        // height, and a flex that overflows it by six pixels in one language
        // is a striped bar across the top of the app. It has to be told to
        // expand — a stack whose children are all positioned shrinks to
        // nothing and then centres itself, which puts the headline in the
        // middle of the sky.
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: kilo.space.s1,
              right: kilo.space.s2,
              // The theme draws icon buttons in the ink used on paper. These
              // sit on the artwork, so they are overridden here rather than
              // by every caller remembering to pass a colour.
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(
                    foregroundColor: kilo.color.contentInverse,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const KModeToggle(),
                    if (onOpenTickets != null)
                      IconButton(
                        onPressed: onOpenTickets,
                        icon: const Icon(Icons.confirmation_number_outlined),
                        tooltip: context.t('travel.tickets.open'),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: kilo.space.s4,
              right: kilo.space.s4,
              bottom: kilo.space.s4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t('travel.search.title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: kilo.text.display.copyWith(
                      color: kilo.color.contentInverse,
                    ),
                  ),
                  SizedBox(height: kilo.space.s1),
                  Text(
                    context.t('travel.search.tagline'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: kilo.text.body.copyWith(
                      color: kilo.color.contentInverse.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CityPicker extends StatelessWidget {
  const _CityPicker({
    required this.label,
    required this.hint,
    required this.cities,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final List<CityOption> cities;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: kilo.text.label.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s2),
        Container(
          height: kilo.space.touchTarget,
          padding: EdgeInsets.symmetric(horizontal: kilo.space.s3),
          decoration: BoxDecoration(
            color: kilo.color.surfaceRaised,
            borderRadius: kilo.radius.controlBorder,
            border: Border.all(color: kilo.color.borderStrong),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              hint: Text(
                hint,
                style: kilo.text.body.copyWith(color: kilo.color.contentMuted),
                overflow: TextOverflow.ellipsis,
              ),
              items: [
                for (final city in cities)
                  DropdownMenuItem(
                    value: city.code,
                    child: Text(city.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: onChanged,
              style: kilo.text.bodyLg.copyWith(
                color: kilo.color.contentPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DateChoice extends StatelessWidget {
  const _DateChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Material(
      color: selected ? kilo.color.brandPrimarySoft : kilo.color.surfaceRaised,
      borderRadius: kilo.radius.controlBorder,
      child: InkWell(
        onTap: onTap,
        borderRadius: kilo.radius.controlBorder,
        child: Container(
          height: kilo.space.touchTarget,
          padding: EdgeInsets.symmetric(horizontal: kilo.space.s3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: kilo.radius.controlBorder,
            border: Border.all(
              color: selected
                  ? kilo.color.brandPrimary
                  : kilo.color.borderStrong,
              width: selected ? 2 : 1,
            ),
          ),
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: kilo.text.body.copyWith(
              color: selected
                  ? kilo.color.brandPrimaryStrong
                  : kilo.color.contentPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _PassengerStepper extends StatelessWidget {
  const _PassengerStepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Row(
      children: [
        _StepButton(
          icon: Icons.remove,
          // Six is the counter limit an agent would sell without checking with
          // somebody, and it is the same cap the server enforces.
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
        ),
        Expanded(
          child: Text(
            context.tPlural('travel.search.passengersLabel', value),
            textAlign: TextAlign.center,
            style: kilo.text.bodyLg,
          ),
        ),
        _StepButton(
          icon: Icons.add,
          onPressed: value < 6 ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Material(
      color: kilo.color.surfaceRaised,
      shape: CircleBorder(
        side: BorderSide(
          color: onPressed == null
              ? kilo.color.borderSubtle
              : kilo.color.borderStrong,
        ),
      ),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: kilo.space.touchTarget,
          height: kilo.space.touchTarget,
          child: Icon(
            icon,
            color: onPressed == null
                ? kilo.color.contentMuted
                : kilo.color.contentPrimary,
          ),
        ),
      ),
    );
  }
}
