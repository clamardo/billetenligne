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
    this.hasMore = false,
    this.loadingMore = false,
    this.onRefresh,
    this.onLoadMore,
    this.onTryTomorrow,
    this.onWatch,
    this.watching = const <String>{},
    this.cityNames = const {},
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

  /// Whether the server said there is another page. Told rather than guessed
  /// from a full list, so the last page ends cleanly instead of with a
  /// spinner that never resolves.
  final bool hasMore;

  final bool loadingMore;

  final Future<void> Function()? onRefresh;

  /// Asked for when the traveller reaches the end of what has loaded.
  ///
  /// Scroll-triggered rather than a button: on this market's connections the
  /// second page takes a moment, and a traveller who has to find and press
  /// something to see the 14:00 mostly does not.
  final VoidCallback? onLoadMore;

  final VoidCallback? onTryTomorrow;

  /// Offered on full coaches only. A sold-out card is not tappable — there is
  /// nothing behind it to book — so without this the row is a dead end, and
  /// "the 06:00 is full" is the moment a traveller is most willing to be
  /// told when that changes.
  final void Function(DepartureSummaryDto)? onWatch;

  /// Departure ids already being waited on. Drawn as a state rather than an
  /// offer: asking twice is asking once on the server, and a button that
  /// re-offers something already done reads as one that did nothing.
  final Set<String> watching;

  /// Code to name — `DLS` to *Dolisie*. The server sends the towns a coach
  /// passes through as codes, because it already sent this client the city
  /// catalogue and a server that sent names would be sending prose in
  /// whichever language the row was written in (ADR-0008).
  final Map<String, String> cityNames;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    final list = departures.isEmpty
        ? KStateView(
            KEmpty(
              art: KArt.noTrips,
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
            // One extra row when there is more: the foot of the list, which
            // is both the "still loading" line and the thing whose being
            // built means the traveller has scrolled far enough to want it.
            itemCount: departures.length + (hasMore ? 1 : 0),
            separatorBuilder: (_, _) => SizedBox(height: kilo.space.s3),
            itemBuilder: (context, index) {
              if (index == departures.length) return _foot(context);

              final d = departures[index];
              final card = KTripCard(
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
                accentColor: AccentHue.tryByName(d.operatorAccentHue)?.color,
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
                // Only when it is a choice. A company with one yard per city
                // would otherwise print the same line on every row, and a
                // label that is always there is a label nobody reads.
                boardingLabel: _boardingLabel(departures, d),
                // The towns on the road, and worded as a road rather than as
                // an offer: this is still a Brazzaville–Pointe-Noire ticket,
                // and buying a seat to one of these towns is not built.
                viaLabel: d.via.isEmpty
                    ? null
                    : context.t('travel.results.via', {
                        'cities': [
                          for (final code in d.via) cityNames[code] ?? code,
                        ].join(' · '),
                      }),
                onTap: () => onSelect(d),
              );

              // The alert affordance sits under the card rather than inside
              // it, and only on full coaches. Inside would put a second
              // tappable thing on a row whose whole job is one tap; on every
              // row it would be noise beside eight coaches that can be
              // booked right now.
              if (!d.isSoldOut || onWatch == null) return card;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  card,
                  SizedBox(height: kilo.space.s1),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: () => onWatch!(d),
                      icon: Icon(
                        watching.contains(d.id)
                            ? Icons.notifications_active_outlined
                            : Icons.notifications_none,
                        size: 18,
                      ),
                      label: Text(
                        watching.contains(d.id)
                            ? context.t('travel.alert.watching')
                            : context.t('travel.alert.confirm'),
                      ),
                    ),
                  ),
                ],
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
              // "and more" until the list is complete. A count that grows as
              // somebody scrolls is a count that was wrong when they read it.
              context.t(
                hasMore
                    ? 'travel.results.subtitleMore'
                    : 'travel.results.subtitle',
                {
                  'date': Format.shortDate(query.date, locale: locale),
                  'count': departures.length,
                },
              ),
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

  /// The end of the list, and the trigger for the next page.
  ///
  /// Asking from `itemBuilder` rather than from a scroll listener: the
  /// framework builds this row exactly when it is about to come into view,
  /// which is the question a scroll listener is trying to answer with
  /// arithmetic.
  Widget _foot(BuildContext context) {
    final kilo = context.kilo;

    // After the frame, never during it: asking for the next page from inside
    // a build emits a step, which rebuilds this widget, which is the error
    // Flutter refuses at exactly the right moment.
    if (!loadingMore && onLoadMore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onLoadMore!());
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: kilo.space.s5),
      child: Center(
        child: SizedBox(
          height: 24,
          width: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    );
  }

  Widget _refreshable(Widget child) => onRefresh == null
      ? child
      : RefreshIndicator(onRefresh: onRefresh!, child: child);

  /// The yard's name, but only when this list actually offers a choice of
  /// yards.
  ///
  /// One terminal per city is the normal case, and printing "Gare de Mikalou"
  /// on all eleven rows teaches somebody to stop reading the line — which is
  /// exactly the line that matters on the day one coach leaves from
  /// Kinsoundi instead. Compared across the whole result set rather than
  /// against the operator's own rows: a traveller choosing between two
  /// companies is choosing between two addresses too.
  static String? _boardingLabel(
    List<DepartureSummaryDto> all,
    DepartureSummaryDto d,
  ) {
    final name = d.originStation?.name;
    if (name == null) return null;
    final distinct = {
      for (final other in all)
        if (other.originStation != null) other.originStation!.name,
    };
    return distinct.length > 1 ? name : null;
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
