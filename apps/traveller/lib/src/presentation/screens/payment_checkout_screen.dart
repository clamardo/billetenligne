import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/payment_flow.dart';
import '../l10n.dart';

/// The card page is open somewhere else, and this screen is the way back.
///
/// The counterpart of `PaymentWaitingScreen` for a hosted checkout, and a
/// separate screen because the two have nothing in common: one says "look at
/// your handset" and offers a USSD code, this one hands over a link and waits
/// for a browser. Three things carry it:
///
///   * **The button can be pressed again.** A browser that failed to open, a
///     page dismissed by accident, an app killed while somebody was typing —
///     all of them land back here, and the same page is offered rather than a
///     second transaction at the PSP.
///   * **It never claims failure.** Coming back is not evidence of anything.
///     The money is confirmed by polling, exactly as on every other rail, and
///     the poller keeps asking after this screen is gone.
///   * **It says the card is entered on the bank's page, not ours.** That is
///     both true and the reassurance somebody needs before typing a card
///     number into a telephone.
final class PaymentCheckoutScreen extends StatelessWidget {
  const PaymentCheckoutScreen({
    required this.step,
    required this.onOpen,
    required this.onCancel,
    super.key,
  });

  final AwaitingCheckout step;

  /// Opens the PSP's page. A callback rather than a launch from here: which
  /// browser, and whether there is one at all, is the composition root's
  /// business and not this widget's. Null means no browser was wired, and
  /// the link is shown to be copied instead — a page somebody can still reach
  /// beats a dead button.
  final void Function(String url)? onOpen;

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final url = step.checkoutUrl;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(context.t('payment.card.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s5),
          children: [
            SizedBox(height: kilo.space.s5),

            if (url == null) ...[
              // The PSP has not answered with a page yet. A real state, and
              // one worth naming: a browser opening on nothing is worse than
              // a sentence saying to wait a moment.
              const Center(child: CircularProgressIndicator()),
              SizedBox(height: kilo.space.s5),
              Text(
                context.t('payment.card.preparing'),
                style: kilo.text.body,
                textAlign: TextAlign.center,
              ),
            ] else ...[
              Text(
                context.t('payment.card.lead'),
                style: kilo.text.bodyLg,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: kilo.space.s3),
              Text(
                context.t('payment.card.onTheirPage'),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: kilo.space.s6),
              if (onOpen case final open?) ...[
                KButton(
                  label: context.t('payment.card.open'),
                  onPressed: () => open(url),
                ),
                SizedBox(height: kilo.space.s3),
                Text(
                  // Pressing it twice is safe, and saying so is what stops
                  // somebody starting a second payment out of doubt.
                  context.t('payment.card.openAgain'),
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ] else ...[
                Text(
                  context.t('payment.card.copyLink'),
                  style: kilo.text.body,
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: kilo.space.s2),
                SelectableText(
                  url,
                  style: kilo.text.code,
                  textAlign: TextAlign.center,
                ),
              ],
            ],

            SizedBox(height: kilo.space.s5),
            Text(
              // Honest about what backing out does and does not do. Somebody
              // who has already typed a card number must not be told the
              // payment is cancelled — it may well have gone through.
              context.t('payment.waitingExtra.leaveSafely'),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s3),
            KButton(
              label: context.t('payment.waitingExtra.close'),
              tone: KButtonTone.ghost,
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}
