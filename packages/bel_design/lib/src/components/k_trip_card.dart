import 'package:flutter/material.dart';

import '../kilo_theme.dart';
import 'k_card.dart';
import 'k_chip.dart';
import 'k_money.dart';

/// One search result.
///
/// The row a traveller scans a dozen of on a 5-inch screen in a hurry, so it
/// answers the three questions they actually have, in the order they have
/// them: **when does it leave, who runs it, what does it cost.** Everything
/// else is secondary and looks it.
///
/// The departure time is the largest thing on the card. Not the price — people
/// choose a coach by when it goes, and only then check whether they can afford
/// it.
final class KTripCard extends StatelessWidget {
  const KTripCard({
    required this.departureTime,
    required this.arrivalTime,
    required this.operatorName,
    required this.durationLabel,
    required this.totalFormatted,
    required this.seatsLabel,
    required this.onTap,
    this.soldOut = false,
    this.soldOutLabel,
    this.scarce = false,
    this.accentColor,
    this.amenities = const [],
    this.reliabilityLabel,
    this.boardingLabel,
    this.viaLabel,
    super.key,
  });

  final String departureTime;
  final String arrivalTime;
  final String operatorName;
  final String durationLabel;
  final String totalFormatted;

  /// Already pluralised by the caller — the catalog owns plural rules, not the
  /// design system.
  final String seatsLabel;

  final VoidCallback? onTap;
  final bool soldOut;
  final String? soldOutLabel;

  /// True when few seats remain. Rendered as a warning chip, and **only when
  /// it is actually true** — manufactured scarcity is the fastest way to lose
  /// the trust this product runs on.
  final bool scarce;

  final Color? accentColor;
  final List<IconData> amenities;

  /// The operator's on-time record, already worded by the caller — *« 92 % à
  /// l'heure »*. Null when there is not enough history to say anything, and
  /// null draws **nothing**: a blank is honest, and a 0 % chip beside a new
  /// operator would be a judgement we have no data for.
  final String? reliabilityLabel;

  /// Which yard this coach leaves from, when the operator runs more than one
  /// in the city. Absent for the great majority of rows — a company with a
  /// single terminal repeating its name on every result is noise — and
  /// impossible to miss on the rows where it is the fact that matters.
  final String? boardingLabel;

  /// The towns this coach passes through, already worded and joined by the
  /// caller — *« via Kinkala · Dolisie »*. Null on the great majority of
  /// rows, and null draws nothing: a direct road has no stops to list, and a
  /// line that says so on every row is a line nobody reads on the day it
  /// matters.
  ///
  /// It is not an offer. Passing through a town is not the same as selling a
  /// seat to it, and the wording the caller passes has to keep that
  /// difference — the row is still a Brazzaville–Pointe-Noire ticket.
  final String? viaLabel;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final muted = soldOut;

    return Opacity(
      // Dimmed rather than hidden. Seeing that the 06:00 is full is how a
      // traveller learns to book earlier; hiding it makes the service look
      // empty.
      opacity: muted ? 0.6 : 1,
      child: KCard(
        onTap: soldOut ? null : onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A 3 px operator rail. Enough to tell two operators apart in a
            // list; not enough to let one shout over the others.
            Container(
              width: 3,
              height: 52,
              margin: EdgeInsets.only(right: kilo.space.s3),
              decoration: BoxDecoration(
                color: accentColor ?? kilo.color.brandPrimary,
                borderRadius: BorderRadius.all(kilo.radius.pill),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Scaled down rather than wrapped or clipped. The departure
                  // time is the one thing on this card that must always be
                  // readable, and "06:00 → 14:00" broken across two lines
                  // reads as two separate journeys. Narrow screens and long
                  // operator names both squeeze this row.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(departureTime, style: kilo.text.timeHero),
                        SizedBox(width: kilo.space.s2),
                        Icon(
                          Icons.arrow_forward,
                          size: 14,
                          color: kilo.color.contentMuted,
                        ),
                        SizedBox(width: kilo.space.s2),
                        Text(
                          arrivalTime,
                          style: kilo.text.h3.copyWith(
                            color: kilo.color.contentSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: kilo.space.s1),
                  Text(
                    '$operatorName · $durationLabel',
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  // On its own line, with a pin, rather than as a third
                  // clause of the operator row: somebody comparing two
                  // coaches that leave from different yards is making a
                  // journey decision, not reading a label.
                  if (viaLabel != null) ...[
                    SizedBox(height: kilo.space.s1),
                    Row(
                      children: [
                        Icon(
                          Icons.alt_route,
                          size: 13,
                          color: kilo.color.contentMuted,
                        ),
                        SizedBox(width: kilo.space.s1),
                        Expanded(
                          child: Text(
                            viaLabel!,
                            style: kilo.text.bodySm.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (boardingLabel != null) ...[
                    SizedBox(height: kilo.space.s1),
                    Row(
                      children: [
                        Icon(
                          Icons.place_outlined,
                          size: 13,
                          color: kilo.color.contentMuted,
                        ),
                        SizedBox(width: kilo.space.s1),
                        Expanded(
                          child: Text(
                            boardingLabel!,
                            style: kilo.text.bodySm.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  SizedBox(height: kilo.space.s3),
                  Wrap(
                    spacing: kilo.space.s2,
                    runSpacing: kilo.space.s1,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (soldOut && soldOutLabel != null)
                        KChip(soldOutLabel!, tone: KChipTone.danger)
                      else
                        KChip(
                          seatsLabel,
                          tone: scarce ? KChipTone.warning : KChipTone.neutral,
                        ),
                      if (reliabilityLabel != null)
                        KChip(reliabilityLabel!, tone: KChipTone.success),
                      for (final icon in amenities)
                        Icon(icon, size: 14, color: kilo.color.contentMuted),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: kilo.space.s3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                KMoney(totalFormatted),
                SizedBox(height: kilo.space.s1),
                if (!soldOut)
                  Icon(
                    Icons.chevron_right,
                    color: kilo.color.contentMuted,
                    size: 20,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
