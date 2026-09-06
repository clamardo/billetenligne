import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// What this operator owes the platform this month, and how to pay it
/// (`04-payments.md` §6.2 note).
///
/// Deliberately not the statements screen: that one is what the platform paid
/// *this* operator, and this one is what this operator owes the *platform*.
/// The two numbers never net against each other, so they never share a
/// screen either — an operator reading one should never wonder whether it
/// already accounts for the other.
final class BillingScreen extends StatelessWidget {
  const BillingScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final billing = workspace.billing;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        KPageHeader(context.t('console.billing.title')),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('console.billing.subtitle'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s4),

        if (billing == null)
          const SizedBox.shrink()
        else
          _BillingCard(
            billing: billing,
            busy: workspace.busy,
            onPaymentType: (type) => workspace.saveBillingPaymentType(type),
          ),
      ],
    );
  }
}

class _BillingCard extends StatelessWidget {
  const _BillingCard({
    required this.billing,
    required this.busy,
    required this.onPaymentType,
  });

  final PlatformBillingDto billing;
  final bool busy;
  final void Function(String paymentType) onPaymentType;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t('console.billing.period', {
                        'from': _date(billing.periodStart),
                        'to': _date(billing.periodEnd),
                      }),
                      style: kilo.text.body,
                    ),
                    SizedBox(height: kilo.space.s1),
                    KMoney(
                      billing.amountDue.format(locale: context.language),
                      size: KMoneySize.hero,
                      color: billing.status == 'due' ? kilo.color.danger : null,
                    ),
                  ],
                ),
              ),
              KChip(
                context.t('console.billing.status.${billing.status}'),
                tone: billing.status == 'paid'
                    ? KChipTone.success
                    : KChipTone.warning,
              ),
            ],
          ),

          SizedBox(height: kilo.space.s4),
          const Divider(height: 1),
          SizedBox(height: kilo.space.s4),

          Text(
            context.t('console.billing.paymentTypeLabel'),
            style: kilo.text.body,
          ),
          SizedBox(height: kilo.space.s2),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 'bank_transfer',
                icon: const Icon(Icons.account_balance, size: 18),
                label: Text(
                  context.t('console.billing.paymentType.bankTransfer'),
                ),
              ),
              ButtonSegment(
                value: 'card',
                icon: const Icon(Icons.credit_card, size: 18),
                label: Text(context.t('console.billing.paymentType.card')),
              ),
            ],
            selected: {billing.paymentType},
            onSelectionChanged: busy
                ? null
                : (selection) => onPaymentType(selection.first),
          ),

          SizedBox(height: kilo.space.s4),

          if (!billing.available)
            Text(
              context.t('console.billing.unavailable'),
              style: kilo.text.bodySm.copyWith(
                color: kilo.color.contentSecondary,
              ),
            )
          else if (billing.paymentType == 'card')
            _CardInstructions(billing: billing)
          else
            _BankInstructions(billing: billing),
        ],
      ),
    );
  }

  static String _date(DateTime instant) {
    final local = instant.toUtc();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }
}

class _CardInstructions extends StatelessWidget {
  const _CardInstructions({required this.billing});

  final PlatformBillingDto billing;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final url = billing.checkoutUrl;
    if (url == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t('console.billing.card.instructions'),
          style: kilo.text.bodySm.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s2),
        Row(
          children: [
            Expanded(child: SelectableText(url, style: kilo.text.code)),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: context.t('console.billing.copy'),
              onPressed: () => Clipboard.setData(ClipboardData(text: url)),
            ),
          ],
        ),
      ],
    );
  }
}

class _BankInstructions extends StatelessWidget {
  const _BankInstructions({required this.billing});

  final PlatformBillingDto billing;

  @override
  Widget build(BuildContext context) {
    final bankName = billing.bankName;
    final accountName = billing.bankAccountName;
    final accountNumber = billing.bankAccountNumber;
    if (bankName == null || accountName == null || accountNumber == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Line(context.t('console.billing.bank.name'), bankName),
        _Line(context.t('console.billing.bank.accountName'), accountName),
        _AccountNumberLine(
          label: context.t('console.billing.bank.accountNumber'),
          value: accountNumber,
        ),
        if (billing.reference != null)
          _Line(
            context.t('console.billing.bank.reference'),
            billing.reference!,
          ),
      ],
    );
  }
}

class _AccountNumberLine extends StatelessWidget {
  const _AccountNumberLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ),
          Expanded(child: SelectableText(value, style: kilo.text.code)),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: context.t('console.billing.copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ),
          Expanded(child: Text(value, style: kilo.text.bodySm)),
        ],
      ),
    );
  }
}
