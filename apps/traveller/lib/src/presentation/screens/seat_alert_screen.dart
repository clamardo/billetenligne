import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/failure_view.dart';
import '../widgets/formatting.dart';

/// The coach is full, and this is what we can honestly offer.
///
/// The wording is the design. Everything on this screen is arranged around
/// one sentence — *seats go back on sale, nothing is kept for you* — because
/// the natural reading of "we'll let you know" is "you have a seat", and that
/// reading ends with somebody at a station at 05:30 for a coach that filled
/// overnight. So:
///
///   * The body says a seat is **remise en vente**, and says outright that
///     everybody waiting is told at the same moment.
///   * It promises **one message**, not a running commentary. An alert that
///     fires twice is an alert people mute.
///   * The seat count is asked for, not assumed. A family of four is not
///     served by one seat coming free, and telling them it was would be a
///     wasted journey dressed up as good news.
///   * Withdrawing is on the same screen as asking. Somebody who no longer
///     needs the trip should not have to find a settings page to stop us
///     writing to them.
final class SeatAlertScreen extends StatelessWidget {
  const SeatAlertScreen({
    required this.departure,
    required this.seats,
    required this.watching,
    required this.saving,
    required this.maxSeats,
    required this.onSeats,
    required this.onConfirm,
    required this.onCancel,
    required this.onBack,
    this.failure,
    super.key,
  });

  final DepartureSummaryDto departure;
  final int seats;

  /// True once the server holds the alert. It flips this screen from a
  /// request into a confirmation, and it is the server's answer rather than
  /// an optimistic local flag — a promise to message somebody is not one to
  /// make on the strength of a tap.
  final bool watching;

  final bool saving;
  final int maxSeats;
  final void Function(int) onSeats;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onBack;

  /// Why the last attempt did not take. Shown in place of the body rather
  /// than over it: the commonest failure here is the happy one — seats came
  /// back between drawing this screen and tapping — and that is news, not an
  /// error to dismiss.
  final ApiFailure? failure;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: onBack),
        title: Text(context.t('travel.alert.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s5),
          children: [
            Text(
              context.t('travel.alert.lead', {
                'operator': departure.operatorName,
                'route': '${departure.originCity}–${departure.destinationCity}',
                'date': Format.shortDate(departure.departsAt, locale: locale),
                'time': Format.time(departure.departsAt),
              }),
              style: kilo.text.bodyLg,
            ),
            SizedBox(height: kilo.space.s5),

            if (failure case final f?) ...[
              FailureView(f),
              SizedBox(height: kilo.space.s5),
            ],

            if (watching) ...[
              Row(
                children: [
                  Icon(
                    Icons.notifications_active_outlined,
                    color: kilo.color.brandPrimary,
                  ),
                  SizedBox(width: kilo.space.s2),
                  Expanded(
                    child: Text(
                      context.t('travel.alert.watching'),
                      style: kilo.text.h3,
                    ),
                  ),
                ],
              ),
              SizedBox(height: kilo.space.s3),
              Text(
                context.t('travel.alert.watchingBody', {'count': '$seats'}),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s6),
              KButton(
                label: context.t('travel.alert.cancel'),
                tone: KButtonTone.secondary,
                loading: saving,
                onPressed: saving ? null : onCancel,
              ),
              SizedBox(height: kilo.space.s3),
              KButton(
                label: context.t('travel.alert.back'),
                tone: KButtonTone.ghost,
                onPressed: onBack,
              ),
            ] else ...[
              Text(
                context.t('travel.alert.body'),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s6),
              Text(context.t('travel.alert.seats'), style: kilo.text.label),
              SizedBox(height: kilo.space.s2),
              // Chips rather than a stepper: every value is one tap, and the
              // whole range is visible. A stepper on this screen would be
              // four taps to say "we are four".
              Wrap(
                spacing: kilo.space.s2,
                children: [
                  for (var n = 1; n <= maxSeats; n++)
                    ChoiceChip(
                      label: Text('$n'),
                      selected: n == seats,
                      onSelected: saving ? null : (_) => onSeats(n),
                    ),
                ],
              ),
              SizedBox(height: kilo.space.s6),
              KButton(
                label: context.t('travel.alert.confirm'),
                loading: saving,
                onPressed: saving ? null : onConfirm,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
