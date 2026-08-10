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
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(context.t('payment.waiting.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s5),
          children: [
            SizedBox(height: kilo.space.s5),
            const Center(child: CircularProgressIndicator()),
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

            SizedBox(height: kilo.space.s5),
            Text(
              // Honest about what backing out does and does not do. Somebody
              // who has already typed their PIN must not be told the payment
              // is cancelled — it may well have gone through.
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
