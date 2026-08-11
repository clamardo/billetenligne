import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/payment_flow.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// Choosing a wallet and the number to pull from.
///
/// **One screen, not two.** Choosing a carrier and typing a number are the
/// same decision for almost everybody — the number determines the carrier —
/// and splitting them adds a tap to every payment to serve the minority who
/// pay from somebody else's wallet.
///
/// Typing a number re-selects the matching wallet, so somebody who replaces
/// the prefilled MTN number with an Airtel one is not sent into a
/// wrong-carrier refusal they could have been spared.
final class PaymentMethodScreen extends StatefulWidget {
  const PaymentMethodScreen({
    required this.step,
    required this.flow,
    required this.onBack,
    super.key,
  });

  final ChoosingMethod step;
  final PaymentFlow flow;
  final VoidCallback onBack;

  @override
  State<PaymentMethodScreen> createState() => _PaymentMethodScreenState();
}

class _PaymentMethodScreenState extends State<PaymentMethodScreen> {
  late final TextEditingController _number = TextEditingController(
    text: _format(widget.step.payerMsisdn),
  );

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final step = widget.step;

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: widget.onBack),
        title: Text(context.t('payment.method.title'), style: kilo.text.h3),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s4),
          children: [
            KCard(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    context.t('payment.method.toPay'),
                    style: kilo.text.body,
                  ),
                  KMoney(
                    Format.money(step.amount, locale: locale),
                    size: KMoneySize.hero,
                  ),
                ],
              ),
            ),
            SizedBox(height: kilo.space.s5),

            if (step.options.isEmpty)
              KCard(
                child: Text(
                  context.t('payment.method.noRails'),
                  style: kilo.text.body,
                ),
              ),

            for (final option in step.options)
              Padding(
                padding: EdgeInsets.only(bottom: kilo.space.s2),
                child: KCard(
                  onTap: () => widget.flow.chooseRail(option),
                  borderColor: option.railId == step.selected?.railId
                      ? kilo.color.brandPrimary
                      : null,
                  child: Row(
                    children: [
                      // An icon rather than a Radio: the whole card is
                      // already the tap target, so a nested control that also
                      // takes taps is two hit boxes for one decision — and
                      // Radio's own value plumbing is deprecated besides.
                      Icon(
                        option.railId == step.selected?.railId
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: option.railId == step.selected?.railId
                            ? kilo.color.brandPrimary
                            : kilo.color.borderStrong,
                      ),
                      SizedBox(width: kilo.space.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.t(option.labelKey),
                              style: kilo.text.body,
                            ),
                            // The name and the number the money goes to.
                            // Digits with nothing beside them are what a scam
                            // looks like. A card rail has no such number —
                            // the money lands in the processor's merchant
                            // account — so it says what it does instead.
                            Text(
                              option.hostedCheckout
                                  ? context.t('payment.card.tabHint')
                                  : '${option.collectionName} · '
                                        '${Format.msisdn(option.collectionMsisdn)}',
                              style: kilo.text.caption.copyWith(
                                color: kilo.color.contentSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (option.recommended)
                        KChip(
                          context.t('payment.method.yourWallet'),
                          tone: KChipTone.brand,
                        ),
                    ],
                  ),
                ),
              ),

            SizedBox(height: kilo.space.s5),

            // A card is not pushed to a handset, so there is no number to
            // debit and asking for one would be a field with no meaning. The
            // whole block goes, rather than being disabled: a greyed-out
            // field still reads as something the traveller failed to fill in.
            if (_pushesToHandset) ...[
              KField(
                label: context.t('payment.method.payFrom'),
                hint: '06 123 45 67',
                // Said plainly, because somebody paying from a relative's
                // wallet needs to know it is allowed — and this is the
                // commonest way a ticket gets paid for in this market.
                helper: context.t('payment.method.payFromHelp'),
                controller: _number,
                keyboardType: TextInputType.phone,
                error: step.failure == null
                    ? null
                    : context.t(step.failure!.messageKey),
                onChanged: (value) {
                  widget.flow.setPayerNumber(value);
                  setState(() {});
                },
              ),

              if (!step.payingFromOwnNumber && step.accountMsisdn != null) ...[
                SizedBox(height: kilo.space.s2),
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: kilo.color.info),
                    SizedBox(width: kilo.space.s2),
                    Expanded(
                      child: Text(
                        context.t('payment.method.notYourNumber'),
                        style: kilo.text.caption.copyWith(
                          color: kilo.color.info,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ] else
              KCard(
                child: Text(
                  context.t('payment.card.lead'),
                  style: kilo.text.body,
                ),
              ),

            SizedBox(height: kilo.space.s5),
            KButton(
              label: context.t('payment.method.continueLabel'),
              onPressed: _ready ? widget.flow.review : null,
              disabledHint: context.t('payment.method.needNumber'),
            ),
          ],
        ),
      ),
    );
  }

  /// Whether the chosen rail asks a handset for a PIN. Read from the option
  /// rather than from its id, so a rail added by configuration behaves
  /// correctly without a new branch here.
  bool get _pushesToHandset => !(widget.step.selected?.hostedCheckout ?? false);

  bool get _ready =>
      widget.step.selected != null &&
      (!_pushesToHandset ||
          _number.text.replaceAll(RegExp(r'[^0-9]'), '').length >= 9);

  static String _format(String e164) => e164.isEmpty ? '' : Format.msisdn(e164);
}
