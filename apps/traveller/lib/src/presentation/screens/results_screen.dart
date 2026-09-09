import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/filter_sheet.dart';
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
    this.onRefine,
    this.operators = const {},
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

  /// The same road and day, ordered or narrowed differently (§6.1).
  ///
  /// The screen builds the query; the flow only runs it. The refined query
  /// never carries the old cursor — a keyset names a position in one
  /// particular order, and carrying it into another is the mistake §6.2
  /// exists to refuse.
  final void Function(SearchDeparturesQuery)? onRefine;

  /// Every company seen on this road and day, id to name.
  ///
  /// Accumulated across the searches of one road rather than read off the
  /// rows on screen: a list filtered to one company can no longer name the
  /// others, and a filter that cannot be undone from the sheet that set it is
  /// a trap.
  final Map<String, String> operators;

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

    // An empty list means two different things, and offering the wrong one
    // sends somebody looking for another day's coach when today's is sitting
    // behind a filter they set thirty seconds ago.
    final narrowed = query.isFiltered && onRefine != null;

    final list = departures.isEmpty
        ? KStateView(
            KEmpty(
              art: KArt.noTrips,
              title: context.t(
                narrowed
                    ? 'travel.results.filteredEmptyTitle'
                    : 'travel.results.emptyTitle',
              ),
              body: context.t(
                narrowed
                    ? 'travel.results.filteredEmptyBody'
                    : 'travel.results.emptyBody',
              ),
              actionLabel: narrowed
                  ? context.t('travel.results.clearFilters')
                  : onTryTomorrow == null
                  ? null
                  : context.t('travel.results.tryTomorrow'),
              onAction: narrowed ? _clearFilters : onTryTomorrow,
            ),
          )
        : CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.all(kilo.space.s4),
                sliver: SliverList.separated(
                  // The loading row is the last item of the list, never a
                  // sliver of its own. A `SliverToBoxAdapter` takes an
                  // already-built widget, so `_foot` — and the next-page
                  // request inside it — would run on every build rather than
                  // when somebody scrolls to it: the screen quietly pulled
                  // every page the moment it opened, which on this market's
                  // connections is the whole point of paging undone.
                  itemCount: departures.length + (hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => SizedBox(height: kilo.space.s3),
                  itemBuilder: (context, index) {
                    if (index == departures.length) return _foot(context);

                    final d = departures[index];
                    final card = KTripCard(
                      departureTime: Format.time(d.departsAt),
                      arrivalTime: Format.time(d.arrivesAt),
                      operatorName: d.operatorName,
                      durationLabel: Format.duration(
                        d.duration,
                        locale: locale,
                      ),
                      totalFormatted: Format.money(d.total, locale: locale),
                      seatsLabel: context.tPlural(
                        'common.units.seatsLeft',
                        d.seatsAvailable,
                      ),
                      soldOut: d.isSoldOut,
                      soldOutLabel: context.t('common.units.soldOut'),
                      // Under a fifth of the coach left. True scarcity, computed
                      // from the same number that is shown.
                      scarce:
                          !d.isSoldOut && d.seatsAvailable <= d.capacity ~/ 5,
                      accentColor: AccentHue.tryByName(
                        d.operatorAccentHue,
                      )?.color,
                      // The company, recognisable. A row is a choice between
                      // companies, and the mark is what somebody who heard
                      // the name at a station is looking for. Never left
                      // blank: a company with no logo gets its monogram in
                      // its own accent, which is what the storefront and the
                      // console header already draw.
                      mark: KOperatorMark(
                        name: d.operatorName,
                        accent:
                            AccentHue.tryByName(d.operatorAccentHue) ??
                            AccentHue.foret,
                        logoUrl: d.operatorLogoUrl,
                      ),
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
                                for (final code in d.via)
                                  cityNames[code] ?? code,
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
                ),
              ),
              // The tail. Another page behind it makes it the loading line;
              // nothing behind it makes it the end of the road, and
              // `hasScrollBody: false` is what lets that panel take exactly
              // the space the coaches did not — two departures on a tall
              // handset used to leave two thirds of the screen blank, which
              // reads as a list still arriving rather than as a quiet day.
              //
              // The cards keep their own size throughout. Stretching two rows
              // to fill a screen would be inventing importance they do not
              // have.
              if (!hasMore)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _endOfRoad(context, locale),
                ),
            ],
          );

    return Scaffold(
      appBar: KJourneyBar(
        leading: BackButton(onPressed: onBack),
        title: context.t('travel.results.title', {
          'from': query.originCity,
          'to': query.destinationCity,
        }),
        // "and more" until the list is complete. A count that grows as
        // somebody scrolls is a count that was wrong when they read it.
        subtitle: context.t(
          hasMore ? 'travel.results.subtitleMore' : 'travel.results.subtitle',
          {
            'date': Format.shortDate(query.date, locale: locale),
            'count': departures.length,
          },
        ),
      ),
      body: SafeArea(
        // The controls sit above the scroller, not inside it. Somebody who
        // has filtered the day down to nothing has to be able to undo it
        // without a list to scroll — and a sort row that scrolls away is one
        // a traveller re-finds by flicking upward.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (onRefine != null) _controls(context),
            Expanded(
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
          ],
        ),
      ),
    );
  }

  /// Order, and how much is hidden.
  ///
  /// **The sort is chips and the filters are a sheet**, and the difference is
  /// the point: reordering hides nothing and is worth one tap, while
  /// narrowing takes things away and is worth a considered screen. Putting
  /// them in one control would make "le moins cher" feel like a commitment.
  ///
  /// Only the filters carry a count. A badge on a sort would be counting a
  /// list that is all still there.
  Widget _controls(BuildContext context) {
    final kilo = context.kilo;
    final refine = onRefine!;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: kilo.space.s4),
      child: Row(
        children: [
          for (final sort in TripSort.values) ...[
            KChoiceChip(
              label: context.t(sort.labelKey),
              selected: query.sort == sort,
              // Re-asking for the order it already has would throw the list
              // away and fetch the same rows back.
              onPressed: query.sort == sort
                  ? null
                  : () => refine(query.refined(sort: sort)),
            ),
            SizedBox(width: kilo.space.s2),
          ],
          KChoiceChip(
            label: query.isFiltered
                ? context.t('travel.results.filterCount', {
                    'count': _filterCount,
                  })
                : context.t('travel.results.filter'),
            icon: Icons.tune,
            selected: query.isFiltered,
            onPressed: () => _openFilters(context, refine),
          ),
        ],
      ),
    );
  }

  /// How many of the three narrowings are on. The window counts once: it is
  /// one question with two ends, and counting it twice would say "3" for a
  /// traveller who chose *matin*.
  int get _filterCount =>
      (query.operatorId != null ? 1 : 0) +
      (query.departFromHour != null || query.departToHour != null ? 1 : 0) +
      (query.maxFareMinor != null ? 1 : 0);

  Future<void> _openFilters(
    BuildContext context,
    void Function(SearchDeparturesQuery) refine,
  ) async {
    final refined = await showFilterSheet(
      context,
      query: query,
      operators: operators,
      departures: departures,
    );
    // Null is the traveller backing out, which is not a search.
    if (refined != null) refine(refined);
  }

  void _clearFilters() => onRefine?.call(
    query.refined(clearOperator: true, clearWindow: true, clearCeiling: true),
  );

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

  /// The foot of a complete list.
  ///
  /// Two coaches on a tall handset left two thirds of the screen empty, and
  /// an empty two thirds reads as a list still loading rather than a day
  /// with two departures on it. The road drawing closes the page and says
  /// which day it was, and the one thing worth offering at the end of a
  /// short day sits on it: the next day.
  ///
  /// Deliberately not a stretched card. Making the two results taller to
  /// fill the space would be inventing importance the rows do not have.
  Widget _endOfRoad(BuildContext context, String locale) {
    final kilo = context.kilo;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        kilo.space.s4,
        0,
        kilo.space.s4,
        kilo.space.s4,
      ),
      child: ClipRRect(
        borderRadius: kilo.radius.cardBorder,
        // The height here is a floor, not the answer. `SliverFillRemaining`
        // hands this child tight constraints covering whatever the coaches
        // left, and tight constraints win over a `SizedBox` — so the panel
        // is exactly as tall as the gap it is closing, on every handset,
        // without measuring anything.
        //
        // Not a `LayoutBuilder`: that cannot report an intrinsic height, and
        // `hasScrollBody: false` asks for one. The list rendered as an empty
        // page when it did.
        child: KScene(
          KSceneArt.roadtrip,
          height: 200,
          // The words sit on the drawing, so the drawing is dimmed under
          // them. Sky is the lightest part of this scene and the ink is
          // the brand's own light one — without the scrim the sentence
          // lands on the one band of the picture it cannot be read on.
          overlay: true,
          // A scrim under the words, not a wash over the picture.
          //
          // `overlay` dims the drawing evenly, which is not the same
          // thing as making one sentence readable: the coach's own body
          // is the palest band in this scene, and light ink laid across
          // it disappears exactly where the sentence sits. The gradient
          // is transparent over the sky and opaque where the text is, so
          // the artwork stays a picture and the words stay words —
          // whatever drawing is behind them.
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.45, 1],
                colors: [
                  kilo.color.brandPrimaryStrong.withValues(alpha: 0),
                  kilo.color.brandPrimaryStrong.withValues(alpha: 0.95),
                ],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(kilo.space.s4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.t('travel.results.endOfDay', {
                      'date': Format.shortDate(query.date, locale: locale),
                    }),
                    style: kilo.text.body.copyWith(
                      color: kilo.color.onBrandPrimary,
                    ),
                  ),
                  if (onTryTomorrow != null) ...[
                    SizedBox(height: kilo.space.s3),
                    // Left, and only as wide as its words. A full-width
                    // button at the foot of a page reads as the thing the
                    // page is for, and this page is for the coaches above
                    // it.
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: KButton(
                        label: context.t('travel.results.tryTomorrow'),
                        onPressed: onTryTomorrow,
                        tone: KButtonTone.secondary,
                        fullWidth: false,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
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
