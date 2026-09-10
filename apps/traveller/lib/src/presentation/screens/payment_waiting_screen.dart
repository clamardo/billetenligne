import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/payment_flow.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// The prompt is on the handset and nobody has typed a PIN yet.
///
/// The most anxious thirty seconds in the product. Three things carry it:
///
///   * **It says what the traveller should be looking at** — their own
///     handset, not this screen. People stare at the app and miss the prompt.
///   * **The USSD code is offered as a fallback.** Push prompts genuinely
///     fail on these networks, and somebody with a way to pay by hand beats
///     somebody watching a spinner.
///   * **It never claims failure.** Losing signal here is not a failed
///     payment, and the poller keeps asking after this screen is gone.
final class PaymentWaitingScreen extends StatelessWidget {
  const PaymentWaitingScreen({
    required this.step,
    required this.onCancel,
    super.key,
  });

  final AwaitingPin step;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      appBar: KJourneyBar(
        automaticallyImplyLeading: false,
        title: context.t('payment.waiting.title'),
      ),
      body: KPattern(
        opacity: 0.05,
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: EdgeInsets.all(kilo.space.s5),
                sliver: SliverList.list(
                  children: [
                    SizedBox(height: kilo.space.s5),
                    Center(
                      child: SizedBox(
                        width: 96,
                        height: 96,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: kilo.color.brandPrimarySoft,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(
                              width: 96,
                              height: 96,
                              child: CircularProgressIndicator(),
                            ),
                            Icon(
                              // Names where to look: their own handset, not this
                              // screen — people stare at the app and miss the prompt.
                              Icons.smartphone,
                              color: kilo.color.brandPrimary,
                              size: 32,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: kilo.space.s5),

                    Text(
                      context.t('payment.waitingExtra.checkPhone', {
                        'msisdn': Format.msisdn(step.payerMsisdn),
                      }),
                      style: kilo.text.bodyLg,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: kilo.space.s3),
                    Text(
                      context.t('payment.confirm.step2'),
                      style: kilo.text.body.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    SizedBox(height: kilo.space.s6),

                    if (step.option.ussdCode != null)
                      KCard(
                        child: Column(
                          children: [
                            Text(
                              context.t('payment.waiting.noPromptTitle'),
                              style: kilo.text.bodySm,
                              textAlign: TextAlign.center,
                            ),
                            SizedBox(height: kilo.space.s2),
                            SelectableText(
                              step.option.ussdCode!,
                              style: kilo.text.h2.copyWith(
                                color: kilo.color.brandPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // A wait is the screen most likely to be stared at, and a field
              // of bare ground is what makes one feel stuck. The road closes
              // it — the thing being waited for.
              SliverFillRemaining(
                hasScrollBody: false,
                child: const KClosingScene(art: KSceneArt.journey),
              ),
            ],
          ),
        ),
      ),
      // The same bar every funnel screen ends on (`KActionBar`), and the one
      // sentence somebody needs before pressing it goes in the slot made for
      // a line of reassurance — honest about what backing out does and does
      // not do. Somebody who has already typed their PIN must not be told
      // the payment is cancelled: it may well have gone through.
      bottomNavigationBar: KActionBar(
        above: Text(
          context.t('payment.waitingExtra.leaveSafely'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
          textAlign: TextAlign.center,
        ),
        child: KButton(
          label: context.t('payment.waitingExtra.close'),
          tone: KButtonTone.ghost,
          onPressed: onCancel,
        ),
      ),
    );
  }
}
