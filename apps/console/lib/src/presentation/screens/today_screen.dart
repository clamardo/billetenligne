import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';
import '../widgets/manifest_sheet.dart';

/// The dispatcher's day.
///
/// The first screen the console opens on, because it is the one somebody
/// looks at every morning. One row per departure, and the load factor is the
/// point of each row.
///
/// **Held is shown beside sold, never folded into it.** A coach that is
/// "48 of 49 sold" and one that is "20 sold, 28 held" are completely
/// different situations twenty minutes before departure — the first is nearly
/// full, the second is twenty-eight people who may or may not turn up at an
/// agency, and a dispatcher deciding whether to add a second coach needs to
/// know which they are looking at.
final class TodayScreen extends StatelessWidget {
  const TodayScreen({required this.workspace, super.key});

  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.all(kilo.space.s4),
          child: Row(
            children: [
              // Flexible, not a fixed Text plus a Spacer: the console runs in
              // whatever window an agency happens to have open, and a header
              // that overflows at 900px is a header that hides the date
              // controls on half the laptops in the country.
              Expanded(
                child: Text(
                  context.t('console.today.title'),
                  style: kilo.text.h2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // A local calendar day. "Departures on the 15th" is a local
              // question, and a UTC comparison puts the 06:00 coach on the
              // wrong day.
              IconButton(
                tooltip: context.t('console.today.previous'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => workspace.showDay(
                  workspace.day.subtract(const Duration(days: 1)),
                ),
              ),
              Text(_dayLabel(workspace.day), style: kilo.text.h3),
              IconButton(
                tooltip: context.t('console.today.next'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () => workspace.showDay(
                  workspace.day.add(const Duration(days: 1)),
                ),
              ),
              SizedBox(width: kilo.space.s3),
              KButton(
                label: context.t('common.actions.retry'),
                tone: KButtonTone.ghost,
                fullWidth: false,
                icon: Icons.refresh,
                onPressed: workspace.refresh,
              ),
            ],
          ),
        ),

        if (workspace.board.isEmpty)
          Expanded(
            child: KStateView(
              KEmpty(
                title: context.t('console.today.emptyTitle'),
                // Names the cause rather than shrugging. On a day with no
                // departures the answer is almost always "the timetable was
                // never published", and that is two clicks away.
                body: context.t('console.today.emptyBody'),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.symmetric(horizontal: kilo.space.s4),
              itemCount: workspace.board.length,
              separatorBuilder: (_, _) => SizedBox(height: kilo.space.s2),
              itemBuilder: (context, i) =>
                  _DepartureRow(row: workspace.board[i], workspace: workspace),
            ),
          ),
      ],
    );
  }

  static String _dayLabel(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _DepartureRow extends StatelessWidget {
  const _DepartureRow({required this.row, required this.workspace});

  final DepartureBoardDto row;
  final ConsoleWorkspace workspace;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return KCard(
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(_time(row.departsAt), style: kilo.text.amount),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.routeCode,
                  style: kilo.text.body,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  row.vehicle ?? context.t('console.today.noVehicle'),
                  overflow: TextOverflow.ellipsis,
                  style: kilo.text.caption.copyWith(
                    // A departure with no coach is the thing on this screen
                    // most worth noticing.
                    color: row.vehicle == null
                        ? kilo.color.danger
                        : kilo.color.contentSecondary,
                  ),
                ),
              ],
            ),
          ),

          _Count(
            label: context.t('console.today.sold'),
            value: '${row.sold}',
            tone: kilo.color.success,
          ),
          _Count(
            label: context.t('console.today.held'),
            value: '${row.held}',
            tone: kilo.color.warning,
          ),
          _Count(
            label: context.t('console.today.free'),
            value: '${row.available}',
            tone: kilo.color.contentSecondary,
          ),

          SizedBox(width: kilo.space.s3),
          KButton(
            label: context.t('console.today.manifest'),
            tone: KButtonTone.secondary,
            fullWidth: false,
            onPressed: () => _showManifest(context),
          ),
        ],
      ),
    );
  }

  Future<void> _showManifest(BuildContext context) async {
    final manifest = await workspace.manifest(row.id);
    if (manifest == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ManifestSheet(manifest: manifest),
    );
  }

  static String _time(DateTime instant) {
    // Congo is UTC+1 and does not observe daylight saving, so the offset is a
    // constant rather than a lookup. Named here because it is the kind of
    // simplification that has to be revisited the day a second market lands.
    final local = instant.toUtc().add(const Duration(hours: 1));
    return '${local.hour.toString().padLeft(2, '0')}h'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, required this.tone});

  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: kilo.space.s3),
      child: Column(
        children: [
          Text(value, style: kilo.text.amount.copyWith(color: tone)),
          Text(
            label,
            style: kilo.text.caption.copyWith(
              color: kilo.color.contentSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
