import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';
import '../widgets/formatting.dart';

/// The applications waiting on a decision, and the roster.
///
/// One screen for both, because they are one list with one default filter.
/// The difference is intent: the queue is worked oldest-first against an SLA
/// (90% of complete applications decided within 48 hours), and the roster is
/// where somebody goes months later to change what an operator negotiated.
///
/// **Oldest first, always** — that ordering is the server's, and it is the
/// whole reason this is a queue rather than a report. A queue worked
/// newest-first has a permanently abandoned tail, and the tail is what the
/// SLA is a promise about.
final class QueueScreen extends StatelessWidget {
  const QueueScreen({
    required this.workspace,
    this.showFilters = false,
    super.key,
  });

  final AdminWorkspace workspace;

  /// The roster shows them; the queue does not. A filter on a list whose
  /// whole definition is "these five statuses" is a control that can only
  /// contradict the heading above it.
  final bool showFilters;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final operators = workspace.operators;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Text(
          context.t(showFilters ? 'admin.nav.operators' : 'admin.queue.title'),
          style: kilo.text.h1,
        ),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('admin.queue.subtitle', {'count': operators.length}),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s4),

        if (showFilters) ...[
          Wrap(
            spacing: kilo.space.s2,
            children: [
              _Filter(
                label: context.t('admin.queue.filterAll'),
                statuses: const {},
                workspace: workspace,
              ),
              _Filter(
                label: context.t('admin.queue.filterPending'),
                statuses: AdminOperatorDto.pendingStatuses,
                workspace: workspace,
              ),
              _Filter(
                label: context.t('admin.queue.filterActive'),
                statuses: const {'active'},
                workspace: workspace,
              ),
              _Filter(
                label: context.t('admin.queue.filterSuspended'),
                statuses: const {'suspended'},
                workspace: workspace,
              ),
            ],
          ),
          SizedBox(height: kilo.space.s4),
        ],

        if (operators.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              art: KArt.emptyBox,
              title: context.t('admin.queue.emptyTitle'),
              body: context.t('admin.queue.emptyBody'),
            ),
          )
        else
          for (final operator in operators)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: OperatorRow(
                operator: operator,
                onOpen: () => workspace.open(operator.id),
              ),
            ),
      ],
    );
  }
}

/// One operator, as a row in either list.
final class OperatorRow extends StatelessWidget {
  const OperatorRow({required this.operator, required this.onOpen, super.key});

  final AdminOperatorDto operator;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final waited = DateTime.now().toUtc().difference(operator.createdAt);

    return KCard(
      onTap: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        operator.legalName,
                        style: kilo.text.body,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(width: kilo.space.s2),
                    Text(
                      operator.code,
                      style: kilo.text.code.copyWith(
                        color: kilo.color.contentSecondary,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: kilo.space.s1),
                Text(
                  context.t('admin.queue.counts', {
                    'vehicles': operator.vehicleCount,
                    'routes': operator.routeCount,
                    'staff': operator.staffCount,
                  }),
                  style: kilo.text.caption.copyWith(
                    color: kilo.color.contentSecondary,
                  ),
                ),
                SizedBox(height: kilo.space.s2),
                Wrap(
                  spacing: kilo.space.s2,
                  runSpacing: kilo.space.s1,
                  children: [
                    KChip(
                      context.t('admin.status.${operator.status}'),
                      tone: statusTone(operator.status),
                    ),
                    // The band the pass wrote, and only when it has looked.
                    // Absent is not `low`: one is a judgement and the other
                    // is the absence of one, and a queue that drew them the
                    // same would let an unassessed file read as cleared.
                    if (operator.riskBand != null)
                      KChip(
                        context.t('enum.RiskBand.${operator.riskBand}'),
                        tone: riskTone(operator.riskBand!),
                        icon: Icons.rule,
                      ),
                    KChip(
                      context.t('admin.queue.commission', {
                        'rate': CommissionTerm(operator.commissionBps).display,
                      }),
                    ),
                    KChip(
                      context.t('admin.queue.documents', {
                        'count': operator.documentCount,
                      }),
                      icon: Icons.description_outlined,
                    ),
                    // Only when there is something to say. A zero here is a
                    // badge that trains people to ignore the badge.
                    if (operator.expiringDocumentCount > 0)
                      KChip(
                        context.t('admin.queue.expiring', {
                          'count': operator.expiringDocumentCount,
                        }),
                        tone: KChipTone.warning,
                        icon: Icons.schedule,
                      ),
                  ],
                ),
                // Named, not counted. "3 signaux" tells a reviewer to open
                // the file to find out what they are, which is the click this
                // whole sorting exists to save.
                if (operator.riskReasons.isNotEmpty) ...[
                  SizedBox(height: kilo.space.s1),
                  Text(
                    [
                      for (final code in operator.riskReasons)
                        context.t('admin.risk.$code'),
                    ].join(' · '),
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: kilo.space.s3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                waited.inDays < 1
                    ? context.t('admin.queue.waitingToday')
                    : context.t('admin.queue.waiting', {'days': waited.inDays}),
                style: kilo.text.caption.copyWith(
                  // A file that has waited more than two days is the SLA
                  // breaking, and it says so in the one place a reviewer
                  // scans.
                  color: waited.inDays >= 2
                      ? kilo.color.warning
                      : kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s1),
              Text(
                Format.date(operator.createdAt),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One tone per stage of the lifecycle, so a roster reads at a glance.
/// Elevated is the only one that is red. `standard` is the ordinary case —
/// most operators are simply bigger than the automatic bar — and colouring it
/// as a warning would make the queue look alarming on a normal Tuesday.
KChipTone riskTone(String band) => switch (band) {
  'elevated' => KChipTone.danger,
  'low' => KChipTone.success,
  _ => KChipTone.neutral,
};

KChipTone statusTone(String status) => switch (status) {
  'active' || 'approved' => KChipTone.success,
  'suspended' || 'rejected' || 'offboarded' => KChipTone.danger,
  'info_requested' || 'offboarding' => KChipTone.warning,
  _ => KChipTone.neutral,
};

class _Filter extends StatelessWidget {
  const _Filter({
    required this.label,
    required this.statuses,
    required this.workspace,
  });

  final String label;
  final Set<String> statuses;
  final AdminWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final selected = _setEquals(workspace.filter, statuses);
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => workspace.showFilter(statuses),
    );
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
