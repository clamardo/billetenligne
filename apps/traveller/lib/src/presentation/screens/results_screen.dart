import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// The departures for a route on a day.
///
/// Sold-out coaches are **shown, dimmed**, not filtered out. Seeing that the
/// 06:00 is full is how a traveller learns to book earlier next time; hiding
/// it makes the service look empty and makes us look like we have no
/// operators.
///
/// Scarcity is shown only when it is true. Congo's coach market runs on
/// word of mouth, and an operator caught inflating "2 places restantes" would
/// take the whole platform's credibility with them.
final class ResultsScreen extends StatelessWidget {
  const ResultsScreen({
    required this.query,
    required this.departures,
    required this.onSelect,
    required this.onBack,
    this.stale = false,
    this.onRefresh,
    this.onTryTomorrow,
    super.key,
  });

  final SearchDeparturesQuery query;
  final List<DepartureSummaryDto> departures;
  final void Function(DepartureSummaryDto) onSelect;
  final VoidCallback onBack;

  /// True when these came from the last successful load. Rendered with a
  /// banner rather than silently: old times are useful, secretly old times
  /// are a lie.
  final bool stale;

  final Future<void> Function()? onRefresh;
  final VoidCallback? onTryTomorrow;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    final list = departures.isEmpty
        ? KStateView(
            KEmpty(
              title: context.t('travel.results.emptyTitle'),
              body: context.t('travel.results.emptyBody'),
              actionLabel: onTryTomorrow == null
                  ? null
                  : context.t('travel.results.tryTomorrow'),
              onAction: onTryTomorrow,
            ),
          )
        : ListView.separated(
            padding: EdgeInsets.all(kilo.space.s4),
            itemCount: departures.length,
            separatorBuilder: (_, _) => SizedBox(height: kilo.space.s3),
            itemBuilder: (context, index) {
              final d = departures[index];
              return KTripCard(
                departureTime: Format.time(d.departsAt),
                arrivalTime: Format.time(d.arrivesAt),
                operatorName: d.operatorName,
                durationLabel: Format.duration(d.duration, locale: locale),
                totalFormatted: Format.money(d.total, locale: locale),
                seatsLabel: context.tPlural(
                  'common.units.seatsLeft',
                  d.seatsAvailable,
                ),
                soldOut: d.isSoldOut,
                soldOutLabel: context.t('common.units.soldOut'),
                // Under a fifth of the coach left. True scarcity, computed
                // from the same number that is shown.
                scarce: !d.isSoldOut && d.seatsAvailable <= d.capacity ~/ 5,
                accentColor: _accent(context, d.operatorAccentHue),
                amenities: _amenityIcons(d.amenities),
                // Only when the server has a figure. It sends none until the
                // operator has run enough coaches for one to mean something,
                // and inventing "no data" wording here would put a sentence
                // about our own gaps onto a search result.
                reliabilityLabel: d.onTimeRate == null
                    ? null
                    : context.t('travel.results.onTime', {
                        'rate': '${d.onTimeRate}',
                      }),
                onTap: () => onSelect(d),
              );
            },
          );

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onBack),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              context.t('travel.results.title', {
                'from': query.originCity,
                'to': query.destinationCity,
              }),
              style: kilo.text.h3,
            ),
            Text(
              context.t('travel.results.subtitle', {
                'date': Format.shortDate(query.date, locale: locale),
                'count': departures.length,
              }),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: stale
            ? KStateView(
                KOffline(
                  title: context.t('travel.results.offlineTitle'),
                  body: context.t('travel.results.offlineBody'),
                  cached: _refreshable(list),
                ),
              )
            : _refreshable(list),
      ),
    );
  }

  Widget _refreshable(Widget child) => onRefresh == null
      ? child
      : RefreshIndicator(onRefresh: onRefresh!, child: child);

  /// The operator's accent, from the closed set of eight. An unknown value
  /// falls back to the brand rather than throwing: an operator vitrine edited
  /// by a future console must never be able to crash a traveller's search.
  static Color? _accent(BuildContext context, String? hue) {
    if (hue == null) return null;
    for (final accent in AccentHue.values) {
      if (accent.name == hue) return accent.color;
    }
    return null;
  }

  static List<IconData> _amenityIcons(List<String> amenities) => [
    for (final a in amenities)
      if (_icons[a] != null) _icons[a]!,
  ];

  static const _icons = <String, IconData>{
    'wifi': Icons.wifi,
    'usb': Icons.usb,
    'ac': Icons.ac_unit,
    'toilet': Icons.wc,
    'tv': Icons.tv,
    'water': Icons.local_drink,
  };
}
