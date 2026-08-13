import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../widgets/formatting.dart';

/// Reserved, unpaid, with four hours to walk into an agency.
///
/// The end of the app's part in a cash sale, and the whole screen is designed
/// to be read across a counter by somebody who is not holding the phone:
///
///   * **The code is the largest thing on it.** A vendor types what they hear
///     or what they see, and both work better at 32pt.
///   * **The amount is exact and itemised.** A receipt read aloud at a
///     counter has to be checkable, and "12 300" is checkable in a way
///     "about 12 000" is not.
///   * **The deadline is a time, not a countdown.** Four hours is long enough
///     that a ticking clock is stressful and useless; "before 14h30" is what
///     somebody plans their afternoon around.
///
/// It deliberately does **not** show a QR. There is no ticket yet — the money
/// has not moved — and a screen that looked like a ticket before payment is
/// the single most confusing thing this flow could do.
final class ReservedScreen extends StatelessWidget {
  const ReservedScreen({
    required this.booking,
    required this.onDone,
    this.onPayNow,
    super.key,
  });

  final BookingDto booking;
  final VoidCallback onDone;

  /// Pay by mobile money instead of walking in. Null when no rail is
  /// available — and the screen then says nothing about it rather than
  /// showing a button that cannot work.
  final VoidCallback? onPayNow;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final code = booking.paymentCode;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(context.t('travel.reserved.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            KCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    context.t('travel.reserved.payAtAgency', {
                      'operator': booking.operatorName,
                    }),
                    style: kilo.text.body,
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: kilo.space.s4),

                  if (code != null)
                    Semantics(
                      label: context.t('travel.reserved.codeLabel'),
                      child: SelectableText(
                        // Spaced, because a five-character code read aloud is
                        // read in pieces and typed in pieces.
                        code.split('').join(' '),
                        textAlign: TextAlign.center,
                        style: kilo.text.codeHero.copyWith(
                          color: kilo.color.brandPrimary,
                          letterSpacing: 2,
                        ),
                      ),
                    ),

                  SizedBox(height: kilo.space.s3),
                  KButton(
                    label: context.t('common.actions.copy'),
                    tone: KButtonTone.ghost,
                    onPressed: code == null
                        ? null
                        : () => Clipboard.setData(ClipboardData(text: code)),
                  ),
                ],
              ),
            ),

            SizedBox(height: kilo.space.s4),

            KCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _line(
                    context,
                    context.t('travel.reserved.reference'),
                    booking.ref,
                  ),
                  _line(
                    context,
                    context.t('travel.reserved.route'),
                    '${booking.originCity} → ${booking.destinationCity}',
                  ),
                  _line(
                    context,
                    context.t('travel.reserved.departure'),
                    '${Format.shortDate(booking.departsAt, locale: locale)} ${Format.time(booking.departsAt)}',
                  ),
                  _line(
                    context,
                    context.t('travel.reserved.seats'),
                    booking.passengers
                        .map((p) => p.seatLabel ?? '')
                        .where((s) => s.isNotEmpty)
                        .join(', '),
                  ),
                  const Divider(),
                  if (booking.fare != null)
                    _line(
                      context,
                      context.t('travel.reserved.fare'),
                      Format.money(booking.fare!, locale: locale),
                    ),
                  if (booking.serviceFee != null)
                    _line(
                      context,
                      context.t('travel.reserved.serviceFee'),
                      Format.money(booking.serviceFee!, locale: locale),
                    ),
                  _line(
                    context,
                    context.t('travel.reserved.total'),
                    Format.money(booking.total, locale: locale),
                    strong: true,
                  ),
                ],
              ),
            ),

            SizedBox(height: kilo.space.s4),

            if (booking.paymentDeadline != null)
              Text(
                // A time, not a countdown. Four hours of ticking clock is
                // stressful and useless; "before 14h30" is what somebody
                // plans an afternoon around.
                context.t('travel.reserved.deadline', {
                  'time': Format.time(booking.paymentDeadline!),
                }),
                style: kilo.text.body.copyWith(color: kilo.color.warning),
                textAlign: TextAlign.center,
              ),

            SizedBox(height: kilo.space.s3),
            Text(
              context.t('travel.reserved.afterPayment'),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
              textAlign: TextAlign.center,
            ),

            SizedBox(height: kilo.space.s5),

            if (onPayNow != null) ...[
              // Offered above "done", because paying now is what most people
              // came to do — the agency code is the fallback for somebody
              // without a wallet, not the other way round.
              KButton(
                label: context.t('travel.reserved.payNow'),
                icon: Icons.smartphone,
                onPressed: onPayNow,
              ),
              SizedBox(height: kilo.space.s2),
            ],

            KButton(
              label: context.t('travel.reserved.payLater'),
              tone: KButtonTone.secondary,
              onPressed: onDone,
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context,
    String label,
    String value, {
    bool strong = false,
  }) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: kilo.space.s2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: kilo.text.bodySm.copyWith(
              color: kilo.color.contentSecondary,
            ),
          ),
          Text(value, style: strong ? kilo.text.amount : kilo.text.body),
        ],
      ),
    );
  }
}
