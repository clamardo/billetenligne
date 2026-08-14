import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/admin_workspace.dart';
import '../l10n.dart';

/// Where people leave (`04-payments.md` §8).
///
/// **This screen is honest about what it cannot see.** It counts from the
/// moment a seat is held, because that is the first thing that leaves a row.
/// Everything before it — a search, a results list scrolled past, a fare
/// somebody thought was too much — is invisible here, and the note at the top
/// says so. A funnel whose first step is unlabelled gets read as
/// search-to-ticket, and then somebody makes a decision about pricing from a
/// number that never measured pricing.
///
/// One row per day, newest first, and the days with nothing on them are drawn
/// too: the alert this screen exists for is a day-over-day fall, and a
/// fortnight with Sundays missing compares Monday with Saturday.
final class FunnelScreen extends StatelessWidget {
  const FunnelScreen({required this.workspace, super.key});

  final AdminWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final funnel = workspace.funnel;
    final days = funnel?.days ?? const <FunnelDayDto>[];
    final worst = funnel?.worstDrop;

    return ListView(
      padding: EdgeInsets.all(kilo.space.s4),
      children: [
        Text(context.t('admin.funnel.title'), style: kilo.text.h1),
        SizedBox(height: kilo.space.s1),
        Text(
          context.t('admin.funnel.countsFrom'),
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        SizedBox(height: kilo.space.s3),

        // The alert from §8, drawn where the numbers are rather than mailed
        // somewhere: ten points off yesterday means a rail or the funnel is
        // broken, and the person who can tell which is the one reading this.
        if (worst != null && worst >= 10)
          Padding(
            padding: EdgeInsets.only(bottom: kilo.space.s3),
            child: KCard(
              child: Row(
                children: [
                  Icon(Icons.trending_down, color: kilo.color.danger),
                  SizedBox(width: kilo.space.s3),
                  Expanded(
                    child: Text(
                      context.t('admin.funnel.drop', {'points': worst}),
                      style: kilo.text.body.copyWith(color: kilo.color.danger),
                    ),
                  ),
                ],
              ),
            ),
          ),

        Wrap(
          spacing: kilo.space.s2,
          children: [
            for (final window in const [7, 14, 30])
              ChoiceChip(
                label: Text(context.t('admin.funnel.days', {'n': window})),
                selected: workspace.funnelDays == window,
                onSelected: (_) => workspace.showFunnelDays(window),
              ),
          ],
        ),
        SizedBox(height: kilo.space.s4),

        if (days.isEmpty && !workspace.busy)
          KStateView(
            KEmpty(
              art: KArt.route,
              title: context.t('admin.funnel.emptyTitle'),
              body: context.t('admin.funnel.emptyBody'),
            ),
          )
        else
          for (final day in days)
            Padding(
              padding: EdgeInsets.only(bottom: kilo.space.s2),
              child: _DayRow(day: day),
            ),
      ],
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day});

  final FunnelDayDto day;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final overall = day.holdToPaid;

    return KCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(day.day, style: kilo.text.h3)),
              // No figure at all when nothing was held, rather than 0%.
              if (overall != null)
                KChip(
                  context.t('admin.funnel.rate', {'rate': overall}),
                  tone: overall >= 50
                      ? KChipTone.success
                      : overall >= 25
                      ? KChipTone.warning
                      : KChipTone.danger,
                )
              else
                KChip(context.t('admin.funnel.quiet')),
            ],
          ),
          SizedBox(height: kilo.space.s2),
          // The three counts and the two rates between them, in the order
          // they happen. The denominators are on screen beside the rates, so
          // "40%" can never be read without "of five".
          Wrap(
            spacing: kilo.space.s4,
            runSpacing: kilo.space.s1,
            children: [
              _Step(
                label: context.t('admin.funnel.held'),
                value: '${day.held}',
              ),
              _Step(
                label: context.t('admin.funnel.reserved'),
                value: '${day.reserved}',
                rate: day.holdToReservation,
              ),
              _Step(
                label: context.t('admin.funnel.paid'),
                value: '${day.paid}',
                rate: day.reservationToPaid,
              ),
            ],
          ),
          if (day.holdsLapsed > 0 || day.paymentsFailed > 0) ...[
            SizedBox(height: kilo.space.s2),
            Text(
              context.t('admin.funnel.lost', {
                'lapsed': day.holdsLapsed,
                'failed': day.paymentsFailed,
              }),
              style: kilo.text.caption.copyWith(
                color: kilo.color.contentSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.label, required this.value, this.rate});

  final String label;
  final String value;
  final int? rate;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tabular figures: three counts in a column that do not line up
            // are three counts nobody compares at a glance.
            Text(value, style: kilo.text.amount),
            if (rate != null) ...[
              SizedBox(width: kilo.space.s2),
              Text(
                context.t('admin.funnel.rate', {'rate': rate!}),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
