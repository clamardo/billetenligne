import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../../application/console_workspace.dart';
import '../l10n.dart';
import '../widgets/disruption_sheet.dart';
import '../widgets/manifest_sheet.dart';
import '../widgets/protection_sheet.dart';
import '../widgets/rebook_sheet.dart';
import '../widgets/rescue_sheet.dart';

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
          child: KPageHeader(
            context.t('console.today.title'),
            // The day controls are this page's action. The title itself is
            // Expanded inside the header rather than a Text with a Spacer:
            // the console runs in whatever window an agency happens to have
            // open, and a header that overflows at 900px is a header that
            // hides the date controls on half the laptops in the country.
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
        ),

        // The four figures a dispatcher looks for before they look at any
        // row. They were all on the board already, one departure at a time,
        // which meant the question *how is today going* was answered by
        // reading forty rows and adding up.
        if (workspace.board.isNotEmpty) _Summary(board: workspace.board),

        if (workspace.board.isEmpty)
          Expanded(
            child: KStateView(
              KEmpty(
                art: KArt.noTrips,
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

class _Summary extends StatelessWidget {
  const _Summary({required this.board});

  final List<DepartureBoardDto> board;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    var sold = 0;
    var free = 0;
    var disrupted = 0;
    for (final row in board) {
      sold += row.sold;
      free += row.available;
      if (row.disruption != null) disrupted++;
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
        kilo.space.s4,
        0,
        kilo.space.s4,
        kilo.space.s3,
      ),
      child: Card(
        // Full width, not shrink-wrapped. A `Wrap` sizes to its content and a
        // `Card` sizes to its child, so the strip stopped wherever the last
        // figure did — a box floating over a list of full-width rows, which
        // reads as unfinished rather than as the summary of them.
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: kilo.space.s5,
              vertical: kilo.space.s4,
            ),
            child: Wrap(
              spacing: kilo.space.s8,
              runSpacing: kilo.space.s4,
              children: [
                KStat(
                  value: '${board.length}',
                  label: context.t('console.today.departures'),
                ),
                KStat(value: '$sold', label: context.t('console.today.sold')),
                KStat(value: '$free', label: context.t('console.today.free')),
                // Only when there is one. A zero in red beside three healthy
                // figures is a number somebody checks every morning for
                // nothing, and it is how a real one stops being noticed.
                if (disrupted > 0)
                  KStat(
                    value: '$disrupted',
                    label: context.t('console.today.disrupted'),
                    tone: kilo.color.danger,
                    icon: Icons.warning_amber_rounded,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
                // A Wrap rather than a Row: the badge is as long as its
                // longest label and the console runs in whatever window an
                // agency happens to have open. Wrapping onto a second line at
                // 900px is a row that still reads; a Row there is an overflow
                // stripe across the screen somebody watches every morning.
                Wrap(
                  spacing: kilo.space.s2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      row.routeCode,
                      style: kilo.text.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // What is happening to this coach, beside its name. A
                    // dispatcher glancing at the day must not have to open a
                    // row to find out one of them is broken down.
                    if (row.disruption != null)
                      KChip(
                        context.t(
                          'disruption.kind.${row.disruption!.kind.name}',
                        ),
                        tone: KChipTone.danger,
                      ),
                    // And what the departure itself is. The board query has
                    // no status filter, so a cancelled coach is on this list
                    // — and it was drawn identically to one that is running,
                    // which is the one row on the screen somebody must not
                    // mistake. `scheduled` says nothing: a label on every row
                    // is a label nobody reads.
                    if (row.status != 'scheduled')
                      KChip(
                        context.t('console.today.status.${row.status}'),
                        tone: row.status == 'cancelled'
                            ? KChipTone.danger
                            : KChipTone.neutral,
                      ),
                  ],
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
          // Flexible around a Wrap, for the same reason the route line is a
          // Wrap: a disrupted row carries three buttons and the console runs
          // in whatever window an agency happens to have open. Wrapping onto
          // a second line at 1000px is a row that still reads; a Row there is
          // an overflow stripe across the screen somebody watches every
          // morning.
          // `Expanded`, not `Flexible`. Flexible is loose: the Wrap shrank
          // to its buttons, `WrapAlignment.end` had nothing to align inside,
          // and the unused half of the allotment sat as dead space at the end
          // of every row on the screen.
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: kilo.space.s2,
              runSpacing: kilo.space.s2,
              children: [
                KButton(
                  label: context.t('console.today.manifest'),
                  tone: KButtonTone.secondary,
                  fullWidth: false,
                  onPressed: () => _showManifest(context),
                ),
                // Only for somebody who holds the capability. Cancelling a
                // coach and telling everybody on it is not a counter agent's
                // authority.
                if (workspace.can('disruption.declare'))
                  KButton(
                    label: context.t('console.today.declare'),
                    tone: KButtonTone.secondary,
                    fullWidth: false,
                    onPressed: () => _declare(context),
                  ),
                // Only on a departure that has actually lost its coach —
                // after a breakdown was declared, or after the vehicle was
                // taken off the road. A swap button on every one of the day's
                // rows is a button pressed by accident on the wrong row, and
                // this one re-signs forty-two tickets.
                if (workspace.can('disruption.declare') &&
                    (row.disruption != null || row.vehicle == null))
                  KButton(
                    label: context.t('console.today.rescue'),
                    fullWidth: false,
                    onPressed: () => _rescue(context),
                  ),
                // The other half of §2.2: when there is no spare, the
                // passengers go on a later departure instead. Offered on the
                // same rows, because it is the same question — this coach is
                // not going, so what happens to the people on it?
                if (workspace.can('disruption.declare') &&
                    (row.disruption != null || row.vehicle == null))
                  KButton(
                    label: context.t('console.today.rebook'),
                    tone: KButtonTone.secondary,
                    fullWidth: false,
                    onPressed: () => _rebook(context),
                  ),
                // Option ③: somebody else's coach. Only when an agreement is
                // actually in force with room left this month — a button that
                // opens onto "aucune compagnie" is a button that costs a
                // dispatcher fifteen seconds they do not have.
                if (workspace.can('disruption.declare') &&
                    workspace.canAskForProtection &&
                    (row.disruption != null || row.vehicle == null))
                  KButton(
                    label: context.t('console.today.protect'),
                    tone: KButtonTone.secondary,
                    fullWidth: false,
                    onPressed: () => _protect(context),
                  ),
              ],
            ),
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

  Future<void> _declare(BuildContext context) async {
    final draft = await showDialog<DisruptionDraft>(
      context: context,
      builder: (_) => DisruptionSheet(
        routeCode: row.routeCode,
        departsAt: row.departsAt,
        sold: row.sold,
      ),
    );
    if (draft == null) return;

    await workspace.declareDisruption(
      departureId: row.id,
      kind: draft.kind,
      cause: draft.cause,
      note: draft.note,
      revisedDepartsAt: draft.revisedDepartsAt,
    );
  }

  Future<void> _rescue(BuildContext context) async {
    // The fleet is fetched at the moment of asking rather than held warm: a
    // dispatcher looking for a spare is doing it once, and a list that is ten
    // minutes stale can offer a coach that has since been sent somewhere else.
    final coaches = await workspace.spareCoaches(excluding: row.vehicle);
    if (!context.mounted) return;

    final draft = await showDialog<RescueDraft>(
      context: context,
      builder: (_) => RescueSheet(
        routeCode: row.routeCode,
        sold: row.sold,
        coaches: coaches,
        currentVehicle: row.vehicle,
      ),
    );
    if (draft == null) return;

    await workspace.assignRescueCoach(
      departureId: row.id,
      vehicleId: draft.vehicleId,
      note: draft.note,
    );
  }

  Future<void> _rebook(BuildContext context) async {
    final draft = await showDialog<RebookDraft>(
      context: context,
      builder: (_) => RebookSheet(
        routeCode: row.routeCode,
        sold: row.sold,
        candidates: workspace.replacementsFor(row),
      ),
    );
    if (draft == null) return;

    await workspace.rebookOnto(
      departureId: row.id,
      replacementDepartureId: draft.replacementDepartureId,
      note: draft.note,
    );
  }

  /// Option ③ of §2.2: ask a company we have an agreement with.
  ///
  /// The candidates are fetched at the moment of asking, like the spare-coach
  /// list and for the same reason: a competitor's free-seat count that is ten
  /// minutes old is a rescue that fails at the door.
  Future<void> _protect(BuildContext context) async {
    final candidates = await workspace.protectionCandidates(row);
    if (!context.mounted) return;

    final draft = await showDialog<ProtectionDraft>(
      context: context,
      builder: (_) => ProtectionSheet(
        routeCode: row.routeCode,
        sold: row.sold,
        candidates: candidates,
      ),
    );
    if (draft == null) return;

    await workspace.askForProtection(
      departureId: row.id,
      replacementDepartureId: draft.replacementDepartureId,
      note: draft.note,
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
