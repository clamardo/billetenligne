import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Choose a seat.
///
/// The screen that makes this product worth using: today a traveller pays and
/// hopes, and the whole pitch is that a seat is *yours*.
///
/// Two decisions worth knowing:
///
///   * **The total is pinned to the bottom and updates as seats are tapped.**
///     Nobody should have to reach the payment screen to find out what four
///     seats cost.
///   * **The availability note is honest and permanent.** Seats really do go
///     while somebody is deciding, and saying so once, quietly, is far better
///     than an apologetic dialog after the fact.
final class SeatMapScreen extends StatelessWidget {
  const SeatMapScreen({
    required this.departure,
    required this.seatMap,
    required this.selected,
    required this.onToggle,
    required this.onContinue,
    required this.onBack,
    this.maxSeats = 6,
    this.holding = false,
    this.capReached = false,
    super.key,
  });

  final DepartureSummaryDto departure;
  final SeatMapDto seatMap;
  final Set<String> selected;

  /// Returns false when the cap refused the tap, so the screen can say why
  /// rather than appear to have stopped responding.
  final void Function(String label) onToggle;

  final VoidCallback onContinue;
  final VoidCallback onBack;
  final int maxSeats;
  final bool holding;
  final bool capReached;

  Money get _fare {
    var minor = 0;
    for (final label in selected) {
      final seat = seatMap.seats.where((s) => s.label == label).firstOrNull;
      minor += seat?.fare?.minor ?? departure.fare.minor;
    }
    return Money(minor, departure.fare.currency);
  }

  Money get _total => _fare + departure.serviceFee;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onBack),
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(context.t('travel.seatmap.title'), style: kilo.text.h3),
            Text(
              '${departure.operatorName} · '
              '${Format.time(departure.departsAt)}',
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.symmetric(horizontal: kilo.space.s4),
          children: [
            SizedBox(height: kilo.space.s3),
            KSeatMap(
              sections: [
                for (final s in seatMap.sections)
                  KSection(
                    code: s.code,
                    label: context.t(s.labelKey),
                    abreast: s.abreast,
                    pitchCm: s.pitchCm,
                  ),
              ],
              seats: [
                for (final s in seatMap.seats)
                  KSeat(
                    label: s.label,
                    sectionCode: s.sectionCode,
                    state: switch (s.status) {
                      SeatStatusDto.available => KSeatState.available,
                      SeatStatusDto.held => KSeatState.held,
                      SeatStatusDto.sold => KSeatState.sold,
                      SeatStatusDto.blocked => KSeatState.blocked,
                    },
                    // Only when this seat costs more than the departure's base
                    // fare. A price on every seat of a flat-fare coach is
                    // noise that hides the one row where it matters.
                    priceHint:
                        s.fare != null && s.fare!.minor != departure.fare.minor
                        ? Format.money(s.fare!, locale: locale)
                        : null,
                  ),
              ],
              selected: selected,
              onToggle: (seat) => onToggle(seat.label),
              maxSelectable: maxSeats,
              labels: KSeatMapLabels(
                front: context.t('travel.seatmap.front'),
                free: context.t('travel.seatmap.free'),
                chosen: context.t('travel.seatmap.chosen'),
                taken: context.t('travel.seatmap.taken'),
              ),
            ),
            SizedBox(height: kilo.space.s4),
            Text(
              context.t('travel.seatmap.availabilityNote'),
              textAlign: TextAlign.center,
              style: kilo.text.caption.copyWith(color: kilo.color.contentMuted),
            ),
            SizedBox(height: kilo.space.s6),
          ],
        ),
      ),
      bottomNavigationBar: _Summary(
        selected: selected,
        capReached: capReached,
        maxSeats: maxSeats,
        totalFormatted: Format.money(_total, locale: locale),
        fareFormatted: Format.money(_fare, locale: locale),
        feeFormatted: Format.money(departure.serviceFee, locale: locale),
        holding: holding,
        onContinue: onContinue,
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.selected,
    required this.capReached,
    required this.maxSeats,
    required this.totalFormatted,
    required this.fareFormatted,
    required this.feeFormatted,
    required this.holding,
    required this.onContinue,
  });

  final Set<String> selected;
  final bool capReached;
  final int maxSeats;
  final String totalFormatted;
  final String fareFormatted;
  final String feeFormatted;
  final bool holding;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final none = selected.isEmpty;

    return Container(
      decoration: BoxDecoration(
        color: kilo.color.surfaceRaised,
        border: Border(top: BorderSide(color: kilo.color.borderSubtle)),
        boxShadow: kilo.elevation.floating,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!none) ...[
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tPlural(
                              'travel.seatmap.selectedCount',
                              selected.length,
                            ),
                            style: kilo.text.body,
                          ),
                          Text(
                            (selected.toList()..sort()).join(' · '),
                            style: kilo.text.bodySm.copyWith(
                              color: kilo.color.contentSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The breakdown, before payment rather than at it. Nobody
                    // should discover the service fee on the last screen.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        KMoney(totalFormatted),
                        Text(
                          '$fareFormatted + $feeFormatted',
                          style: kilo.text.caption.copyWith(
                            color: kilo.color.contentMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                SizedBox(height: kilo.space.s3),
              ],
              if (capReached) ...[
                Text(
                  context.t('travel.seatmap.maxReached', {'max': maxSeats}),
                  style: kilo.text.bodySm.copyWith(color: kilo.color.warning),
                ),
                SizedBox(height: kilo.space.s2),
              ],
              KButton(
                label: none
                    ? context.t('common.actions.next')
                    : context.t('travel.seatmap.continueWith', {
                        'amount': totalFormatted,
                      }),
                loading: holding,
                onPressed: none ? null : onContinue,
                disabledHint: none
                    ? context.t('travel.seatmap.chooseAtLeastOne')
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
