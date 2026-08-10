import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/payment_flow.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// Paid. The receipt.
///
/// The screen somebody screenshots and shows their family, so it carries
/// everything that proves the journey exists: what was paid, from which
/// wallet, for which seats, on which coach, and the reference to quote if
/// anything goes wrong.
///
/// The ticket lives one tap away rather than on this screen. A receipt and a
/// boarding pass are different documents with different lifetimes — one is
/// read once, the other at the roadside on a cracked screen — and merging
/// them makes both worse.
final class PaymentReceiptScreen extends StatelessWidget {
  const PaymentReceiptScreen({
    required this.step,
    required this.onDone,
    super.key,
  });

  final PaymentSucceeded step;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final locale = context.language;
    final booking = step.booking;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s5),
          children: [
            Icon(Icons.check_circle, size: 56, color: kilo.color.success),
            SizedBox(height: kilo.space.s3),
            Text(
              context.t('payment.success.title'),
              style: kilo.text.h2,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s2),
            Center(
              child: KMoney(
                Format.money(step.intent.amount, locale: locale),
                size: KMoneySize.hero,
              ),
            ),
            SizedBox(height: kilo.space.s5),

            KCard(
              child: Column(
                children: [
                  _Line(
                    context.t('payment.receipt.reference'),
                    booking.ref,
                    strong: true,
                  ),
                  const Divider(),
                  _Line(
                    context.t('payment.receipt.route'),
                    '${booking.originCity} → ${booking.destinationCity}',
                  ),
                  _Line(
                    context.t('payment.receipt.departure'),
                    '${Format.shortDate(booking.departsAt, locale: locale)} '
                    '${Format.time(booking.departsAt)}',
                  ),
                  _Line(
                    context.t('payment.receipt.seats'),
                    booking.passengers
                        .map((p) => p.seatLabel ?? '')
                        .where((s) => s.isNotEmpty)
                        .join(', '),
                  ),
                  const Divider(),
                  _Line(
                    context.t('payment.receipt.wallet'),
                    context.t('enum.PaymentRailKind.mobileMoney'),
                  ),
                ],
              ),
            ),

            SizedBox(height: kilo.space.s4),
            Text(
              // The SMS goes through the outbox and may take a minute. Saying
              // "sent" when the drain has not run is how somebody reports
              // never receiving it.
              context.t('payment.success.body'),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
              textAlign: TextAlign.center,
            ),

            SizedBox(height: kilo.space.s5),
            KButton(
              label: context.t('payment.receipt.seeTicket'),
              onPressed: onDone,
            ),
          ],
        ),
      ),
    );
  }
}

/// The rail said no, and said why.
///
/// Twelve codes, twelve sentences, twelve recoveries (`04-payments.md` §5).
/// "Payment failed. Try again." is what this screen exists to prevent — and
/// **retry is offered only when retrying could work**, because a barred
/// subscriber does not become unbarred by tapping again.
final class PaymentRefusedScreen extends StatelessWidget {
  const PaymentRefusedScreen({
    required this.step,
    required this.onRetry,
    required this.onBack,
    super.key,
  });

  final PaymentRefused step;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final code = step.intent.failureCode ?? 'payment.psp_unavailable';

    return Scaffold(
      appBar: AppBar(leading: BackButton(onPressed: onBack)),
      body: SafeArea(
        child: KStateView(
          KFailed(
            title: context.t('payment.refused.title'),
            // The code selects the sentence. The seat is still held for every
            // one of these — that is what `keepsHold` on the failure code is
            // for — and the copy says so.
            body: context.t('errors.$code'),
            retryLabel: step.retryable
                ? context.t('payment.refused.retry')
                : context.t('payment.refused.another'),
            onRetry: step.retryable ? onRetry : onBack,
            traceId: step.intent.id.isEmpty ? null : step.intent.id,
          ),
        ),
      ),
    );
  }
}

/// We stopped being able to tell.
///
/// **This is not a failure screen and must never read like one.** The money
/// may have left their wallet. Somebody is looking at it, the traveller is
/// told exactly that, and they are given the reference to quote — which is
/// the whole of `04-payments.md` §7.5 in one screen.
final class PaymentUnresolvedScreen extends StatelessWidget {
  const PaymentUnresolvedScreen({
    required this.step,
    required this.onDone,
    super.key,
  });

  final PaymentUnresolved step;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(kilo.space.s5),
          children: [
            Icon(Icons.hourglass_top, size: 48, color: kilo.color.warning),
            SizedBox(height: kilo.space.s3),
            Text(
              context.t('payment.pending.title'),
              style: kilo.text.h2,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s3),
            Text(
              context.t('payment.pending.body'),
              style: kilo.text.body,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: kilo.space.s4),
            KCard(
              child: Column(
                children: [
                  Text(
                    context.t('payment.unresolvedRef'),
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                  SizedBox(height: kilo.space.s2),
                  SelectableText(step.intent.id, style: kilo.text.code),
                ],
              ),
            ),
            SizedBox(height: kilo.space.s5),
            KButton(label: context.t('common.actions.done'), onPressed: onDone),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.strong = false});

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
