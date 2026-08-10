import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Which departure the passengers go on instead — option ② of
/// `08-disruption.md` §2.2.
///
/// The answer when there is no spare coach: the 14:00 on the same road has
/// eighteen free seats, so eighteen of the forty-two travel today.
///
/// **Coverage is shown per candidate, before the choice.** "18 / 42" is the
/// number a dispatcher acts on — they will take it and then look for
/// something for the other twenty-four — and a list that showed only free
/// seat counts would make them do that arithmetic in their head while
/// forty-two people watch.
final class RebookSheet extends StatefulWidget {
  const RebookSheet({
    required this.routeCode,
    required this.sold,
    required this.candidates,
    super.key,
  });

  final String routeCode;

  /// Confirmed passengers on the broken departure.
  final int sold;

  /// This operator's own later departures on the same road, as the board
  /// knows them. Filtering happens before the sheet is opened, because a
  /// list that offers a departure the server will refuse is a list that
  /// teaches people our buttons lie.
  final List<DepartureBoardDto> candidates;

  @override
  State<RebookSheet> createState() => _RebookSheetState();
}

/// What the sheet answers with. Null when it was dismissed.
final class RebookDraft {
  const RebookDraft({required this.replacementDepartureId, this.note});

  final String replacementDepartureId;
  final String? note;
}

class _RebookSheetState extends State<RebookSheet> {
  String? _departureId;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 720),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(kilo.space.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.routeCode, style: kilo.text.h3),
              Text(
                context.t('console.rebook.title', {'count': widget.sold}),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s4),

              if (widget.candidates.isEmpty)
                Text(
                  context.t('console.rebook.none'),
                  style: kilo.text.body.copyWith(color: kilo.color.danger),
                )
              else
                for (final departure in widget.candidates)
                  Padding(
                    padding: EdgeInsets.only(bottom: kilo.space.s2),
                    child: _CandidateTile(
                      departure: departure,
                      sold: widget.sold,
                      selected: _departureId == departure.id,
                      onTap: () => setState(() => _departureId = departure.id),
                    ),
                  ),

              if (_departureId != null) ...[
                SizedBox(height: kilo.space.s3),
                KField(
                  label: context.t('console.rebook.note'),
                  helper: context.t('console.rebook.noteHint'),
                  controller: _note,
                  maxLength: 120,
                ),
              ],

              SizedBox(height: kilo.space.s4),
              Row(
                children: [
                  Expanded(
                    child: KButton(
                      label: context.t('console.rebook.back'),
                      tone: KButtonTone.secondary,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SizedBox(width: kilo.space.s3),
                  Expanded(
                    child: KButton(
                      label: context.t('console.rebook.confirm'),
                      onPressed: _departureId == null
                          ? null
                          : () => Navigator.of(context).pop(
                              RebookDraft(
                                replacementDepartureId: _departureId!,
                                note: _note.text.trim().isEmpty
                                    ? null
                                    : _note.text.trim(),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One later departure, and how much of the load it takes.
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.departure,
    required this.sold,
    required this.selected,
    required this.onTap,
  });

  final DepartureBoardDto departure;
  final int sold;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final covers = departure.available < sold ? departure.available : sold;

    return InkWell(
      onTap: onTap,
      borderRadius: kilo.radius.controlBorder,
      child: Container(
        padding: EdgeInsets.all(kilo.space.s3),
        decoration: BoxDecoration(
          borderRadius: kilo.radius.controlBorder,
          border: Border.all(
            color: selected ? kilo.color.brandPrimary : kilo.color.borderSubtle,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 68,
              child: Text(_time(departure.departsAt), style: kilo.text.amount),
            ),
            Expanded(
              child: Text(
                departure.vehicle ?? context.t('console.today.noVehicle'),
                style: kilo.text.caption.copyWith(
                  color: kilo.color.contentSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            SizedBox(width: kilo.space.s2),
            // Coverage, not free seats. The dispatcher's next decision is
            // what to do about whoever this does not take.
            KChip(
              context.t('console.rebook.covers', {
                'covered': covers,
                'total': sold,
              }),
              tone: covers >= sold ? KChipTone.success : KChipTone.warning,
            ),
          ],
        ),
      ),
    );
  }

  /// The same rendering as the day view, and for the same reason: Congo is
  /// UTC+1 with no daylight saving, and a dispatcher comparing this sheet
  /// with the row behind it must not see two different clocks.
  static String _time(DateTime instant) {
    final local = instant.toUtc().add(const Duration(hours: 1));
    return '${local.hour.toString().padLeft(2, '0')}h'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
