import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';

/// What the operator was paid, and why that number (`04-payments.md` §6.2).
///
/// Read-only, and the screen says so rather than leaving somebody hunting for
/// a button: the party being paid cannot move the row that pays them, which
/// the server enforces with a grant.
///
/// Three things this screen refuses to hide:
///
///   * **The cash line.** Never paid out — the operator is already holding
///     that money — and printed anyway, because "where is my cash money?" is
///     the first question anybody asks about a statement.
///   * **The drawer deduction.** The service fee on a cash sale is ours and
///     it is in their till, so it comes off the transfer. An operator who
///     finds that out from a smaller number than they expected phones us; one
///     who reads the line does not.
///   * **A negative week.** If they owe us, the screen says so in their own
///     words rather than showing a payout of nothing.
final class StatementsScreen extends StatelessWidget {
  const StatementsScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final statements = workspace.statements;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Text(context.t('console.statements.title'), style: kilo.text.h2),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('console.statements.subtitle'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s4),

        if (statements.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              title: context.t('console.statements.emptyTitle'),
              body: context.t('console.statements.emptyBody'),
            ),
          )
        else
          for (final run in statements)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _StatementCard(
                run: run,
                // Null outside the browser, where there is nowhere to put a
                // file. A button that cannot hand anybody anything is worse
                // than no button.
                onDownload: workspace.canDownloadStatements
                    ? () => workspace.downloadStatement(run.id)
                    : null,
              ),
            ),
      ],
    );
  }
}

class _StatementCard extends StatelessWidget {
  const _StatementCard({required this.run, this.onDownload});

  final PayoutRunDto run;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final owes = run.operatorOwesUs;

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
                      context.t('console.statements.period', {
                        'from': _date(run.periodStart),
                        'to': _date(run.periodEnd),
                      }),
                      style: kilo.text.body,
                    ),
                    SizedBox(height: kilo.space.s1),
                    KMoney(
                      (owes ? -run.net : run.net).format(
                        locale: context.language,
                      ),
                      size: KMoneySize.hero,
                      color: owes ? kilo.color.danger : null,
                    ),
                    Text(
                      context.t(
                        owes
                            ? 'console.statements.owed'
                            : 'console.statements.paidLabel',
                      ),
                      style: kilo.text.caption.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              KChip(
                context.t('console.statements.state.${run.state}'),
                tone: switch (run.state) {
                  'paid' => KChipTone.success,
                  'approved' => KChipTone.neutral,
                  _ => KChipTone.warning,
                },
              ),
            ],
          ),

          SizedBox(height: kilo.space.s3),
          const Divider(height: 1),
          SizedBox(height: kilo.space.s3),

          _Line(
            context.t('console.statements.online'),
            context.t('console.statements.tickets', {
              'count': run.onlineSalesCount,
              'amount': run.onlineGross.format(locale: context.language),
            }),
          ),
          _Line(
            context.t('console.statements.cash'),
            context.t('console.statements.tickets', {
              'count': run.cashSalesCount,
              'amount': run.cashGross.format(locale: context.language),
            }),
          ),
          // Stated on the statement itself, because it is the number one
          // question and the answer is a sentence, not a figure.
          Padding(
            padding: EdgeInsets.symmetric(vertical: kilo.space.s1),
            child: Text(
              context.t('console.statements.cashNote'),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ),
          _Line(
            context.t('console.statements.commission'),
            run.commission.format(locale: context.language),
          ),
          _Line(
            context.t('console.statements.refunds'),
            run.refunds.format(locale: context.language),
          ),
          _Line(
            context.t('console.statements.tills'),
            run.tills.format(locale: context.language),
          ),
          if (run.paidAt != null)
            _Line(
              context.t('console.statements.paidOn'),
              context.t('console.statements.paidWith', {
                'date': _date(run.paidAt!),
                'reference': run.reference ?? '—',
              }),
            ),

          // The document, not the screen. An accountant files a PDF, a bank
          // asks for one, and a dispute six months from now is settled by
          // what we sent rather than by what this page renders today.
          if (onDownload != null) ...[
            SizedBox(height: kilo.space.s3),
            Align(
              alignment: Alignment.centerLeft,
              child: KButton(
                label: context.t('console.statements.download'),
                icon: Icons.download,
                tone: KButtonTone.secondary,
                fullWidth: false,
                onPressed: onDownload,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime instant) {
    final local = instant.toUtc().add(const Duration(hours: 1));
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
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
