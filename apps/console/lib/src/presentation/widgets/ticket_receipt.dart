import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';

/// What the vendor hands over.
///
/// Shown the instant cash is taken, and it is the only confirmation either
/// party gets at the counter — the SMS goes out through the outbox, which is
/// asynchronous by design and may take a minute.
///
/// The booking reference is the largest thing on it and selectable, because
/// the single most common counter interaction after a sale is a traveller
/// asking for their reference again over the phone.
///
/// It shows the ticket payload as text, not a QR image. The QR belongs on the
/// traveller's phone where it can rotate its freshness code every thirty
/// seconds; a printed one from this screen would be a frozen code that fails
/// the check (ADR-0007). What a vendor needs here is proof the sale happened
/// and a reference to quote.
final class TicketReceipt extends StatelessWidget {
  const TicketReceipt({required this.sale, super.key});

  final CounterSaleDto sale;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.check_circle, size: 48, color: kilo.color.success),
              SizedBox(height: kilo.space.s3),
              Text(
                context.t('console.receipt.paid'),
                style: kilo.text.h3,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: kilo.space.s4),

              SelectableText(
                sale.ref,
                textAlign: TextAlign.center,
                style: kilo.text.display.copyWith(
                  color: kilo.color.brandPrimary,
                ),
              ),
              SizedBox(height: kilo.space.s2),
              KButton(
                label: context.t('common.actions.copy'),
                tone: KButtonTone.ghost,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: sale.ref)),
              ),

              SizedBox(height: kilo.space.s4),
              const Divider(),

              for (final p in sale.passengers)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: kilo.space.s2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(p.fullName, style: kilo.text.body),
                      Text(p.seatLabel ?? '', style: kilo.text.amountSm),
                    ],
                  ),
                ),

              const Divider(),
              Padding(
                padding: EdgeInsets.symmetric(vertical: kilo.space.s2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      context.t('console.receipt.total'),
                      style: kilo.text.body,
                    ),
                    KMoney(sale.total.format(), size: KMoneySize.hero),
                  ],
                ),
              ),

              SizedBox(height: kilo.space.s3),
              Text(
                // Honest about the asynchrony. A vendor telling somebody "it
                // has been sent" when the drain has not run yet is a vendor
                // who will be told it never arrived.
                context.t('console.receipt.smsQueued', {
                  'count': sale.tickets.length,
                }),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
                textAlign: TextAlign.center,
              ),

              SizedBox(height: kilo.space.s5),
              KButton(
                label: context.t('common.actions.done'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
