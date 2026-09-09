import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'formatting.dart';

/// Where the coach is, on the ticket of somebody sitting in it (J6).
///
/// The follower page has drawn this since it shipped, for a relative at the
/// far end holding a link. The passenger on the coach — the one whose phone is
/// already in their hand — could not see it, because the only reader was keyed
/// on a share token. This is the same three tiers of ADR-0014, read through
/// the booking.
///
/// **The confidence line is the widget.** The bar is decoration around it. A
/// coach on the RN1 is four hours out of signal and nobody has usually
/// reported anything, so the honest answer most of the time is *estimation
/// d'après l'horaire* — and a bar drawn without that sentence is a claim
/// somebody acts on, by ringing an agency at Dolisie to ask why the coach is
/// not where the app says. ADR-0014 closes with the instruction to resist
/// exactly this, and the sentence is the same reviewed one the follower page
/// uses because it is the same claim.
///
/// **A list of names, never a map.** The refusal in `07-trip-sharing.md` §5
/// has not changed: a map SDK is megabytes against ADR-0009's 15 MB budget,
/// and a moving dot is a promise this network cannot keep.
class JourneyCard extends StatelessWidget {
  const JourneyCard({required this.journey, super.key});

  final TripJourneyDto journey;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final estimate = journey.isEstimate;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('travel.ticket.journey.title'), style: kilo.text.h3),
          SizedBox(height: kilo.space.s3),

          // First, above the bar. What the bar means is decided here.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                estimate ? Icons.schedule : Icons.check_circle,
                size: 18,
                color: estimate ? kilo.color.contentMuted : kilo.color.success,
              ),
              SizedBox(width: kilo.space.s2),
              Expanded(child: Text(_tierLine(context), style: kilo.text.body)),
            ],
          ),

          SizedBox(height: kilo.space.s3),

          ClipRRect(
            borderRadius: kilo.radius.controlBorder,
            child: LinearProgressIndicator(
              value: journey.progress,
              minHeight: 6,
              backgroundColor: kilo.color.surfaceSunken,
              // Muted on an estimate, and the same muted grey as the sentence
              // beside it. A brand-coloured bar reads as a measurement.
              color: estimate ? kilo.color.contentMuted : kilo.color.success,
            ),
          ),

          SizedBox(height: kilo.space.s2),
          Text(
            context.t('travel.ticket.journey.arrival', {
              'time': Format.time(journey.arrivesAt),
            }),
            style: kilo.text.bodySm.copyWith(color: kilo.color.contentSecondary),
          ),

          // A road with no intermediate stops is a real road — Brazzaville to
          // Pointe-Noire direct — and an empty list under a heading reads as
          // something that failed to load.
          if (journey.stops.isNotEmpty) ...[
            SizedBox(height: kilo.space.s3),
            Divider(height: 1, color: kilo.color.borderSubtle),
            for (final stop in journey.stops) _Stop(stop: stop),
          ],
        ],
      ),
    );
  }

  /// The same sentence the follower page shows, from the same catalog key.
  ///
  /// One reviewed French sentence per claim, whichever surface makes it: the
  /// day the two are written separately is the day one of them stops saying
  /// *aucune position n'a été signalée*.
  String _tierLine(BuildContext context) => switch (journey.trackingTier) {
    TrackingTier.checkpoint => context.t('follow.tier.checkpoint', {
      'place': journey.checkpointName ?? '',
      'time': Format.time(journey.reportedAt ?? journey.departsAt),
    }),
    TrackingTier.gps => context.t('follow.tier.gps', {
      'minutes': journey.reportedAt == null
          ? 0
          : DateTime.now().toUtc().difference(journey.reportedAt!).inMinutes,
    }),
    TrackingTier.schedule => context.t('follow.tier.schedule'),
  };
}

/// One place on the road, and whether the coach is past it.
class _Stop extends StatelessWidget {
  const _Stop({required this.stop});

  final JourneyStopDto stop;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final behind = stop.isBehind;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: kilo.space.s2),
      child: Row(
        children: [
          Icon(
            behind ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: behind ? kilo.color.success : kilo.color.contentMuted,
          ),
          SizedBox(width: kilo.space.s3),
          Expanded(
            child: Text(
              stop.name,
              style: kilo.text.body.copyWith(
                color: behind
                    ? kilo.color.contentPrimary
                    : kilo.color.contentSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            behind
                ? context.t('travel.ticket.journey.passedAt', {
                    'time': Format.time(stop.passedAt!),
                  })
                : context.t('travel.ticket.journey.ahead'),
            style: kilo.text.caption.copyWith(
              color: behind ? kilo.color.success : kilo.color.contentMuted,
            ),
          ),
        ],
      ),
    );
  }
}
