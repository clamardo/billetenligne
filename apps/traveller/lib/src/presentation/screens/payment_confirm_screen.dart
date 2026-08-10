import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/payment_flow.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// The last screen before the money moves.
///
/// **A separate step on purpose.** Everything on it is checkable before
/// anything irreversible happens: the amount, which wallet, the number the
/// money leaves, the number it arrives at, and the operator's name beside
/// that number. Skipping this saves one tap and costs the trust that makes
/// somebody willing to pay by phone at all — which in this market is the
/// whole product.
///
/// It also says what happens next, in order. A traveller who does not know a
/// PIN prompt is coming reads the delay as a failure and taps again.
final class PaymentConfirmScreen extends StatelessWidget {
  const PaymentConfirmScreen({
    required this.step,
    required this.flow,
    required this.onBack,
    super.key,
  });

  final ConfirmingPayment step;
  final PaymentFlow flow;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: step.busy ? null : onBack),
        title: Text(context.t('payment.confirm.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            Center(
              child: KMoney(
                Format.money(step.amount, locale: locale),
                size: KMoneySize.hero,
              ),
            ),
            SizedBox(height: kilo.space.s5),

            KCard(
              child: Column(
                children: [
                  _Line(
                    label: context.t('payment.confirm.wallet'),
                    value: context.t(step.option.labelKey),
                  ),
                  const Divider(),
                  _Line(
                    label: context.t('payment.confirm.from'),
                    value: Format.msisdn(step.payerMsisdn),
                  ),
                  const Divider(),
                  // The two lines that matter most. A number with no name
                  // beside it is what a scam looks like, and this is the last
                  // moment anybody can notice.
                  _Line(
                    label: context.t('payment.confirm.to'),
                    value: Format.msisdn(step.option.collectionMsisdn),
                    strong: true,
                  ),
                  _Line(
                    label: context.t('payment.confirm.toName'),
                    value: step.option.collectionName,
                  ),
                ],
              ),
            ),

            SizedBox(height: kilo.space.s5),

            // What happens next, in order. Somebody who does not know a PIN
            // prompt is coming reads the pause as a failure and taps again.
            Text(context.t('payment.confirm.whatNext'), style: kilo.text.label),
            SizedBox(height: kilo.space.s2),
            for (final step in const [1, 2, 3])
              Padding(
                padding: EdgeInsets.only(bottom: kilo.space.s2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$step. ', style: kilo.text.body),
                    Expanded(
                      child: Text(
                        context.t('payment.confirm.step$step'),
                        style: kilo.text.body,
                      ),
                    ),
                  ],
                ),
              ),

            SizedBox(height: kilo.space.s5),
            KButton(
              label: context.t('payment.confirm.pay', {
                'amount': Format.money(step.amount, locale: locale),
              }),
              loading: step.busy,
              onPressed: flow.pay,
            ),
            SizedBox(height: kilo.space.s2),
            KButton(
              label: context.t('common.actions.back'),
              tone: KButtonTone.ghost,
              onPressed: step.busy ? null : onBack,
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.strong = false});

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
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
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: strong ? kilo.text.amountSm : kilo.text.body,
            ),
          ),
        ],
      ),
    );
  }
}
