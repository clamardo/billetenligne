import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// The payout queue (`04-payments.md` §6.2).
///
/// A work queue, like the reconciliation one: a run sitting unapproved for
/// three days is an operator wondering where their money is, and the only way
/// anybody finds out is by seeing the row.
///
/// **The whole statement is in the row.** Not a summary with a link: the
/// person approving this is agreeing to a number, and they should be able to
/// see the sales, the commission, the refunds and the drawer that produced it
/// without navigating anywhere. The cash line is there even though cash is
/// never paid out — it is the first thing an operator asks about, so it is
/// the first thing the person answering them should be looking at.
final class PayoutsScreen extends StatelessWidget {
  const PayoutsScreen({required this.workspace, super.key});

  final AdminWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final runs = workspace.payouts;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        KPageHeader(
          context.t('admin.payouts.title'),
          subtitle: context.t('admin.payouts.subtitle', {'count': runs.length}),
        ),

        if (runs.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              art: KArt.payment,
              title: context.t('admin.payouts.emptyTitle'),
              body: context.t('admin.payouts.emptyBody'),
            ),
          )
        else
          for (final run in runs)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _RunCard(workspace: workspace, run: run),
            ),
      ],
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.workspace, required this.run});

  final AdminWorkspace workspace;
  final PayoutRunDto run;

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
                    KMoney(
                      run.net.format(locale: context.language),
                      size: KMoneySize.hero,
                      // A negative net is the operator owing us, which is a
                      // conversation rather than a transfer — and it must not
                      // look like an ordinary payout waiting to be pressed.
                      color: run.operatorOwesUs ? kilo.color.danger : null,
                    ),
                    SizedBox(height: kilo.space.s1),
                    Text(
                      run.operatorName ?? run.operatorId,
                      style: kilo.text.body,
                    ),
                    Text(
                      context.t('admin.payouts.period', {
                        'from': Format.date(run.periodStart),
                        'to': Format.date(run.periodEnd),
                      }),
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              KChip(
                context.t('admin.payouts.state.${run.state}'),
                tone: switch (run.state) {
                  'approved' => KChipTone.success,
                  'paid' => KChipTone.neutral,
                  _ => KChipTone.warning,
                },
              ),
            ],
          ),

          SizedBox(height: kilo.space.s3),
          const Divider(height: 1),
          SizedBox(height: kilo.space.s3),

          _Line(
            context.t('admin.payouts.online'),
            context.t('admin.payouts.tickets', {
              'count': run.onlineSalesCount,
              'amount': run.onlineGross.format(locale: context.language),
            }),
          ),
          // Present, and never paid out. "Where is my cash money?" is the
          // first question an operator asks about a statement, every time.
          _Line(
            context.t('admin.payouts.cash'),
            context.t('admin.payouts.tickets', {
              'count': run.cashSalesCount,
              'amount': run.cashGross.format(locale: context.language),
            }),
          ),
          _Line(
            context.t('admin.payouts.commission'),
            run.commission.format(locale: context.language),
          ),
          _Line(
            context.t('admin.payouts.refunds'),
            run.refunds.format(locale: context.language),
          ),
          _Line(
            context.t('admin.payouts.payable'),
            run.payable.format(locale: context.language),
          ),
          // The two halves of the difference, so the person approving can
          // check the number rather than trust it.
          _Line(
            context.t('admin.payouts.tills'),
            run.tills.format(locale: context.language),
          ),
          if (run.destination != null)
            _Line(context.t('admin.payouts.destination'), run.destination!),

          SizedBox(height: kilo.space.s3),
          _Decisions(workspace: workspace, run: run),
        ],
      ),
    );
  }
}

/// Approve, then release. Two buttons that are never both live at once.
class _Decisions extends StatefulWidget {
  const _Decisions({required this.workspace, required this.run});

  final AdminWorkspace workspace;
  final PayoutRunDto run;

  @override
  State<_Decisions> createState() => _DecisionsState();
}

class _DecisionsState extends State<_Decisions> {
  final _reference = TextEditingController();

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final workspace = widget.workspace;
    final run = widget.run;

    final allowed = workspace.can('payout.approve') && workspace.hasReason;
    final hint = !workspace.can('payout.approve')
        ? context.t('admin.operator.notAllowed')
        : context.t('admin.reason.required');

    // Money the wrong way round is an invoice and a conversation. The buttons
    // are not offered at all rather than offered and refused.
    if (run.operatorOwesUs) {
      return Text(
        context.t('admin.payouts.owesUs', {
          'amount': (-run.net).format(locale: context.language),
        }),
        style: kilo.text.bodySm.copyWith(color: kilo.color.danger),
      );
    }

    if (run.state == 'draft') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Said before the button, because it is the reason the button is
          // sometimes refused after being pressed.
          Text(
            context.t('admin.payouts.secondPerson'),
            style: kilo.text.caption.copyWith(
              color: kilo.color.contentSecondary,
            ),
          ),
          SizedBox(height: kilo.space.s2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: KButton(
              label: context.t('admin.payouts.approve'),
              onPressed: allowed
                  ? () => workspace.decidePayout(
                      runId: run.id,
                      decision: 'approve',
                    )
                  : null,
            ),
          ),
          if (!allowed) ...[
            SizedBox(height: kilo.space.s1),
            Text(
              hint,
              style: kilo.text.caption.copyWith(color: kilo.color.warning),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KField(
          label: context.t('admin.payouts.reference'),
          // A transfer nobody can find in a bank statement afterwards is a
          // transfer that gets sent twice.
          helper: context.t('admin.payouts.referenceHint'),
          controller: _reference,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: kilo.space.s2),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: KButton(
            label: context.t('admin.payouts.release'),
            tone: KButtonTone.primary,
            onPressed: allowed && _reference.text.trim().isNotEmpty
                ? () => workspace.decidePayout(
                    runId: run.id,
                    decision: 'release',
                    paymentReference: _reference.text,
                  )
                : null,
          ),
        ),
        if (!allowed) ...[
          SizedBox(height: kilo.space.s1),
          Text(
            hint,
            style: kilo.text.caption.copyWith(color: kilo.color.warning),
          ),
        ],
      ],
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
            width: 180,
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
