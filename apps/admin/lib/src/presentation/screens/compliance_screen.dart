import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';

/// **Conformité** (`03-operator-lifecycle.md` §6): every operator's paperwork,
/// on one screen, worst first.
///
/// A calendar rather than a queue, and the difference matters: nothing here
/// arrived because somebody submitted it. These rows appear because a date is
/// approaching, they are worked weeks before they are urgent, and the deadline
/// arrives whether or not anybody opened this tab — the worker blocks the
/// sales on its own. What this screen is for is the fortnight before that, in
/// which a telephone call still costs less than a company losing a Friday.
///
/// **Already lapsed sorts to the top and is never hidden.** A calendar that
/// only looked forward would drop an operator off the screen at the exact
/// moment they became the reason somebody has to make that call.
final class ComplianceScreen extends StatelessWidget {
  const ComplianceScreen({required this.workspace, super.key});

  final AdminWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final rows = workspace.compliance;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        KPageHeader(
          context.t('admin.compliance.title'),
          subtitle: context.t('admin.compliance.subtitle', {
            'count': rows.length,
          }),
        ),
        SizedBox(height: kilo.space.s3),

        // Sixty days is where the first reminder goes out, so it is the
        // default: everything nearer has already been said to the operator.
        Wrap(
          spacing: kilo.space.s2,
          children: [
            for (final days in const [30, 60, 90, 365])
              ChoiceChip(
                label: Text(
                  context.t('admin.compliance.window', {'days': days}),
                ),
                selected: workspace.complianceDays == days,
                onSelected: (_) => workspace.showComplianceDays(days),
              ),
          ],
        ),
        SizedBox(height: kilo.space.s4),

        if (rows.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              art: KArt.boarding,
              title: context.t('admin.compliance.emptyTitle'),
              body: context.t('admin.compliance.emptyBody'),
            ),
          )
        else
          for (final row in rows)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s3),
              child: _OperatorCard(workspace: workspace, standing: row),
            ),
      ],
    );
  }
}

class _OperatorCard extends StatelessWidget {
  const _OperatorCard({required this.workspace, required this.standing});

  final AdminWorkspace workspace;
  final ComplianceDto standing;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  standing.operatorName ?? standing.operatorId,
                  style: kilo.text.h3,
                ),
              ),
              KChip(
                context.t('enum.ExpiryStage.${standing.stage}'),
                tone: _tone(standing.stage),
              ),
              SizedBox(width: kilo.space.s2),
              // The file is one tap away, because the answer to every row here
              // is a conversation that needs the documents, the staff list and
              // the trail in front of you.
              TextButton(
                onPressed: () => workspace.open(standing.operatorId),
                child: Text(context.t('admin.compliance.open')),
              ),
            ],
          ),
          if (standing.salesBlocked) ...[
            SizedBox(height: kilo.space.s2),
            Text(
              context.t('admin.compliance.blocked', {
                'document': context.t(
                  'enum.DocumentType.${standing.blockedDoc ?? ''}',
                ),
              }),
              style: kilo.text.body.copyWith(color: kilo.color.danger),
            ),
          ],
          SizedBox(height: kilo.space.s3),
          for (final doc in standing.documents)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.t('enum.DocumentType.${doc.docType}'),
                      style: kilo.text.body,
                    ),
                  ),
                  Text(
                    // Signed on purpose: "il y a 3 j" and "dans 3 j" are the
                    // difference between a phone call and a diary note.
                    context.t(
                      doc.daysLeft < 0
                          ? 'admin.compliance.lapsedDays'
                          : 'admin.compliance.remainingDays',
                      {'days': doc.daysLeft.abs()},
                    ),
                    style: kilo.text.caption.copyWith(
                      color: doc.daysLeft < 0
                          ? kilo.color.danger
                          : kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static KChipTone _tone(String stage) => switch (stage) {
    'blocked' || 'suspended' => KChipTone.danger,
    'urgent' => KChipTone.warning,
    _ => KChipTone.neutral,
  };
}
