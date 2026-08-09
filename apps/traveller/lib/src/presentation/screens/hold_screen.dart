import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// The seat is held; the money is not yet taken.
///
/// The most emotionally loaded screen in the product. Somebody has committed
/// to a journey and is now watching a clock, and everything here exists to
/// make that wait survivable:
///
///   * **The countdown is the largest thing on the screen**, because it is the
///     only thing that can go wrong from here.
///   * **The breakdown is itemised**, not a single total. A receipt read aloud
///     at a counter has to be checkable.
///   * **Cancelling is offered plainly**, not buried. A traveller who has
///     changed their mind and cannot find the exit simply closes the app, and
///     then the seat sits held for fifteen minutes for nobody.
final class HoldScreen extends StatelessWidget {
  const HoldScreen({
    required this.departure,
    required this.hold,
    required this.onRelease,
    required this.onExpired,
    required this.onPay,
    this.releasing = false,
    this.now,
    super.key,
  });

  final DepartureSummaryDto departure;
  final HoldDto hold;
  final VoidCallback onRelease;
  final VoidCallback onExpired;

  /// Null until the payment rails land. The button is disabled and *says why*,
  /// which is a far more honest state than a button that opens a screen
  /// apologising.
  final VoidCallback? onPay;

  final bool releasing;

  /// Injectable for tests. The expiry callback releases a seat; leaving it
  /// unverified because the widget reads the wall clock is not an option.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(context.t('travel.hold.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Center(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: kilo.space.s5,
                  vertical: kilo.space.s4,
                ),
                decoration: BoxDecoration(
                  color: kilo.color.brandPrimarySoft,
                  borderRadius: BorderRadius.all(kilo.radius.pill),
                ),
                child: KCountdown(
                  expiresAt: hold.expiresAt,
                  onExpired: onExpired,
                  now: now ?? _systemNow,
                  labelBuilder: (remaining) => context.t(
                    'travel.hold.countdown',
                    {'time': formatCountdown(remaining)},
                  ),
                ),
              ),
            ),
            SizedBox(height: kilo.space.s4),
            Text(
              context.t('travel.hold.body'),
              textAlign: TextAlign.center,
              style: kilo.text.body.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),

            SizedBox(height: kilo.space.s6),
            KCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          departure.operatorName,
                          style: kilo.text.h3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      KChip(
                        '${departure.originCity} → ${departure.destinationCity}',
                        tone: KChipTone.brand,
                      ),
                    ],
                  ),
                  SizedBox(height: kilo.space.s2),
                  Text(
                    '${Format.shortDate(departure.departsAt, locale: locale)} · '
                    '${Format.time(departure.departsAt)} → '
                    '${Format.time(departure.arrivesAt)}',
                    style: kilo.text.body.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                  SizedBox(height: kilo.space.s3),
                  Text(
                    context.t('travel.hold.seatsLabel', {
                      'seats': hold.seatLabels.join(' · '),
                    }),
                    style: kilo.text.amount,
                  ),

                  Padding(
                    padding: EdgeInsets.symmetric(vertical: kilo.space.s4),
                    child: Divider(color: kilo.color.borderSubtle, height: 1),
                  ),

                  _Line(
                    label: context.t('common.labels.fare'),
                    amount: Format.money(hold.fare, locale: locale),
                  ),
                  SizedBox(height: kilo.space.s2),
                  _Line(
                    label: context.t('common.labels.serviceFee'),
                    amount: Format.money(hold.serviceFee, locale: locale),
                  ),
                  SizedBox(height: kilo.space.s3),
                  _Line(
                    label: context.t('common.labels.total'),
                    amount: Format.money(hold.total, locale: locale),
                    emphasis: true,
                  ),
                ],
              ),
            ),

            SizedBox(height: kilo.space.s6),
            KButton(
              label: context.t('travel.hold.proceed', {
                'amount': Format.money(hold.total, locale: locale),
              }),
              onPressed: onPay,
              disabledHint: onPay == null
                  ? context.t('travel.hold.paymentComingSoon')
                  : null,
            ),
            SizedBox(height: kilo.space.s3),
            KButton(
              label: releasing
                  ? context.t('travel.hold.releasing')
                  : context.t('travel.hold.release'),
              tone: KButtonTone.ghost,
              loading: releasing,
              onPressed: releasing ? null : onRelease,
            ),
          ],
        ),
      ),
    );
  }

  static DateTime _systemNow() => DateTime.now().toUtc();
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.amount,
    this.emphasis = false,
  });

  final String label;
  final String amount;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: emphasis
              ? kilo.text.h3
              : kilo.text.body.copyWith(color: kilo.color.contentSecondary),
        ),
        KMoney(
          amount,
          size: emphasis ? KMoneySize.normal : KMoneySize.small,
          color: emphasis ? null : kilo.color.contentSecondary,
        ),
      ],
    );
  }
}
