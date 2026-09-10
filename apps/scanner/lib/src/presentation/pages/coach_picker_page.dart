import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Which of today's coaches is mine?
///
/// The only question between signing in and the door, and the last one that
/// needs a network. Deliberately not the dispatcher's board: no load factor,
/// no held seats, no passenger names — a conductor in a yard at half past
/// five is reading a time and a road, in the sun, holding a phone in one hand.
class CoachPickerPage extends StatelessWidget {
  const CoachPickerPage({
    required this.coaches,
    required this.onPick,
    required this.onRefresh,
    this.pinning,
    this.failure,
    super.key,
  });

  final List<BoardingDepartureDto> coaches;
  final void Function(BoardingDepartureDto) onPick;
  final Future<void> Function() onRefresh;

  /// The one being downloaded, so the row the conductor tapped is the row
  /// that shows it is working.
  final String? pinning;

  final String? failure;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      backgroundColor: kilo.color.surfaceBase,
      // The same woven band the traveller's funnel wears. This is the first
      // screen a conductor sees every morning and it used to be a white list
      // under a white bar: correct, and indistinguishable from any other
      // list on the handset.
      appBar: KJourneyBar(
        title: context.t('scanner.coaches.title'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            onPressed: pinning == null ? onRefresh : null,
            icon: const Icon(Icons.refresh),
            tooltip: context.t('scanner.coaches.refresh'),
          ),
          // Here rather than behind the door: this is the screen every
          // conductor passes through, every morning, and the one they are
          // standing on when they discover the handset is not in a language
          // they read. Behind the door it would be two taps away with sixty
          // people waiting.
          KLanguageMenu(
            tooltip: context.t('common.language'),
            current: context.language,
            languages: [
              for (final language in context.languages)
                (code: language.code, nativeName: language.nativeName),
            ],
            onChanged: context.setLanguage,
          ),
        ],
      ),
      // The traveller's results screen is the recipe: a calm cream ground and
      // white cards that carry their own edge. A woven ground was tried here
      // and reverted — behind borderless tiles the rows dissolved into the
      // pattern and the list read as wallpaper with text on it. The band
      // above carries the brand; the body's job is to stay quiet.
      body: SafeArea(
        child: Column(
          children: [
            if (failure != null)
              Container(
                width: double.infinity,
                color: kilo.color.dangerSoft,
                padding: EdgeInsets.all(kilo.space.s4),
                child: Text(
                  failure!,
                  style: kilo.text.body.copyWith(color: kilo.color.danger),
                ),
              ),
            Expanded(
              child: coaches.isEmpty
                  ? _Empty(onRefresh: onRefresh)
                  : RefreshIndicator(
                      onRefresh: onRefresh,
                      // A scroll view rather than a list, so the space the
                      // coaches leave can be closed by something. Three
                      // departures on a tall handset ended the page halfway
                      // down and left the rest blank; the traveller's results
                      // screen has never done that, and a conductor's first
                      // screen of the day should not look like a different
                      // product from the one their passengers are holding.
                      child: CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              kilo.space.s4,
                              kilo.space.s4,
                              kilo.space.s4,
                              0,
                            ),
                            sliver: SliverList.separated(
                              itemCount: coaches.length,
                              separatorBuilder: (_, _) =>
                                  SizedBox(height: kilo.space.s3),
                              itemBuilder: (context, i) => _CoachTile(
                                coach: coaches[i],
                                busy: pinning == coaches[i].id,
                                enabled: pinning == null,
                                onTap: () => onPick(coaches[i]),
                              ),
                            ),
                          ),
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _EndOfDay(count: coaches.length),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Closes the day, the way the traveller's results screen closes a search.
///
/// `SliverFillRemaining` hands this tight constraints covering exactly what
/// the coaches left, so the panel is as tall as the gap on every handset with
/// nothing measured — and never shorter than its own words when the list is
/// long enough to scroll.
///
/// **Every screen of this product closes.** A band above and nothing below is
/// how a screen stops looking like the app it belongs to.
class _EndOfDay extends StatelessWidget {
  const _EndOfDay({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Padding(
      padding: EdgeInsets.all(kilo.space.s4),
      child: ClipRRect(
        borderRadius: kilo.radius.cardBorder,
        child: KScene(
          // The road, not the terminus. `station` was tried and the full-sun
          // palette turns its awning into a bar of orange across the middle
          // of the panel — `roadtrip` is the scene the traveller's own
          // end-of-list has always used, and it reads in every mode.
          KSceneArt.roadtrip,
          height: 180,
          overlay: true,
          // A scrim under the words rather than a wash over the picture: the
          // palest band of this scene is exactly where the sentence sits.
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.4, 1],
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
                    context.tPlural('scanner.coaches.endOfDay', count),
                    style: kilo.text.body.copyWith(
                      color: kilo.color.onBrandPrimary,
                    ),
                  ),
                  SizedBox(height: kilo.space.s1),
                  Text(
                    context.t('scanner.coaches.endOfDayBody'),
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.onBrandPrimary.withValues(alpha: 0.82),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CoachTile extends StatelessWidget {
  const _CoachTile({
    required this.coach,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final BoardingDepartureDto coach;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final cancelled = coach.status == 'cancelled';

    // The border is what makes a white card legible on a near-white ground.
    // Without one these read as bands rather than cards — the traveller's
    // results screen has carried it since it was written.
    return Container(
      decoration: BoxDecoration(
        color: kilo.color.surfaceRaised,
        borderRadius: kilo.radius.cardBorder,
        border: Border.all(color: kilo.color.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: kilo.radius.cardBorder,
        onTap: enabled && !cancelled ? onTap : null,
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s4),
          child: Row(
            children: [
              // The time first and biggest. It is what a conductor was told
              // this morning, and the only thing they are matching against.
              Text(_hhmm(coach.departsAt), style: kilo.text.time),
              SizedBox(width: kilo.space.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${coach.originCity} → ${coach.destinationCity}',
                      style: kilo.text.h3,
                    ),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      context.tPlural(
                            'scanner.coaches.tickets',
                            coach.expected,
                            {'capacity': coach.capacity},
                          ) +
                          (coach.stationName == null
                              ? ''
                              : ' · ${coach.stationName}'),
                      style: kilo.text.bodySm.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                    if (cancelled) ...[
                      SizedBox(height: kilo.space.s1),
                      Text(
                        context.t('scanner.coaches.cancelled'),
                        style: kilo.text.bodySm.copyWith(
                          color: kilo.color.danger,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (!cancelled)
                Icon(Icons.chevron_right, color: kilo.color.contentMuted),
            ],
          ),
        ),
      ),
    );
  }

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Center(
      child: Padding(
        padding: EdgeInsets.all(kilo.space.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.directions_bus_outlined,
              size: 48,
              color: kilo.color.contentMuted,
            ),
            SizedBox(height: kilo.space.s4),
            Text(
              context.t('scanner.coaches.empty'),
              style: kilo.text.h3,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s2),
            Text(
              context.t('scanner.coaches.emptyBody'),
              style: kilo.text.body.copyWith(
                color: kilo.color.contentSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s5),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: Text(context.t('scanner.coaches.refresh')),
            ),
          ],
        ),
      ),
    );
  }
}
