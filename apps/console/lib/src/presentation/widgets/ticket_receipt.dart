import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/console_workspace.dart';
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
final class TicketReceipt extends StatefulWidget {
  const TicketReceipt({required this.sale, required this.workspace, super.key});

  final CounterSaleDto sale;
  final ConsoleWorkspace workspace;

  @override
  State<TicketReceipt> createState() => _TicketReceiptState();
}

class _TicketReceiptState extends State<TicketReceipt> {
  final _address = TextEditingController();
  String _channel = 'email';
  String? _sentTo;
  bool _sending = false;

  CounterSaleDto get sale => widget.sale;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _sending = true);
    final sent = await widget.workspace.sendTicketLink(
      bookingRef: sale.ref.replaceFirst('BEL-', ''),
      channel: _channel,
      sendTo: _address.text,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sentTo = sent?.sentTo;
    });
  }

  Future<void> _revoke() async {
    setState(() => _sending = true);
    await widget.workspace.revokeTicketLinks(sale.ref.replaceFirst('BEL-', ''));
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sentTo = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Dialog(
      child: ConstrainedBox(
        // The receipt grew a question at the bottom, and a till screen is
        // often a small one. Scrolling rather than shrinking: every line on
        // this dialog is one the vendor reads out.
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
        child: SingleChildScrollView(
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

              SizedBox(height: kilo.space.s4),
              const Divider(),
              SizedBox(height: kilo.space.s3),

              // The question at the till (ADR-0026). It is asked *here*, on
              // the receipt, because this is the only moment the customer is
              // in front of the vendor and can spell their own address — and
              // because a walk-in who leaves without it has a ticket they can
              // reach on paper and nowhere else.
              Text(context.t('console.receipt.sendTitle'), style: kilo.text.h3),
              Text(
                context.t('console.receipt.sendWhy'),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s3),

              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'email',
                    label: Text(context.t('console.receipt.byEmail')),
                    icon: const Icon(Icons.mail_outline),
                  ),
                  ButtonSegment(
                    value: 'phone',
                    label: Text(context.t('console.receipt.byPhone')),
                    icon: const Icon(Icons.sms_outlined),
                  ),
                ],
                selected: {_channel},
                onSelectionChanged: _sending
                    ? null
                    : (choice) => setState(() => _channel = choice.first),
              ),
              SizedBox(height: kilo.space.s3),

              KField(
                label: context.t('console.receipt.address'),
                // Empty means the address already on the account, which for a
                // counter sale is the number the vendor typed to create it.
                // Typing it again is how a wrong one gets in twice.
                hint: context.t('console.receipt.addressHint'),
                controller: _address,
                enabled: !_sending,
                keyboardType: _channel == 'phone'
                    ? TextInputType.phone
                    : TextInputType.emailAddress,
              ),
              SizedBox(height: kilo.space.s3),

              if (_sentTo != null) ...[
                Text(
                  context.t('console.receipt.sentTo', {'a1': _sentTo}),
                  style: kilo.text.bodySm.copyWith(color: kilo.color.success),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: kilo.space.s2),
              ],

              Row(
                children: [
                  Expanded(
                    child: KButton(
                      label: _sentTo == null
                          ? context.t('console.receipt.send')
                          : context.t('console.receipt.sendAgain'),
                      tone: KButtonTone.secondary,
                      onPressed: _sending ? null : _send,
                    ),
                  ),
                  if (_sentTo != null) ...[
                    SizedBox(width: kilo.space.s2),
                    Expanded(
                      child: KButton(
                        label: context.t('console.receipt.revoke'),
                        tone: KButtonTone.ghost,
                        onPressed: _sending ? null : _revoke,
                      ),
                    ),
                  ],
                ],
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
