import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Asking another company for room — option ③ of `08-disruption.md` §2.2.
///
/// The third answer, after the spare coach and the operator's own later
/// departure: a competitor on the same road, with seats, under an agreement
/// signed months ago in an office. It is what already happens on the forecourt
/// at Dolisie; this is the version where the price was agreed in advance and
/// the passenger keeps a ticket that scans.
///
/// What the sheet refuses to blur:
///
///   * **Nothing moves when you press send.** The request lands on the other
///     company's console and waits for a person. The button says *ask*, and
///     the line under it says so again — a dispatcher who reads "envoyé" as
///     "placed" is one who stops looking for a coach.
///   * **Their seat count, before the choice.** A dispatcher picking blind
///     picks the 14:00 with two seats for forty-two people.
///   * **What it will cost, before the choice.** The rebill is the agreed
///     discount on *their* fare, and it is settled between the companies —
///     never with the passenger, who paid already and pays nothing more.
final class ProtectionSheet extends StatefulWidget {
  const ProtectionSheet({
    required this.routeCode,
    required this.sold,
    required this.candidates,
    super.key,
  });

  final String routeCode;

  /// Confirmed passengers on the broken departure — how many need a seat.
  final int sold;

  /// Other companies' departures on the same road, later, with room, under a
  /// live agreement. Filtered before the sheet opens, because a list that
  /// offers what the server will refuse teaches people our buttons lie.
  final List<DepartureSummaryDto> candidates;

  @override
  State<ProtectionSheet> createState() => _ProtectionSheetState();
}

/// What the sheet answers with. Null when it was dismissed.
final class ProtectionDraft {
  const ProtectionDraft({required this.replacementDepartureId, this.note});

  final String replacementDepartureId;
  final String? note;
}

class _ProtectionSheetState extends State<ProtectionSheet> {
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
                context.t('console.protectionAsk.title', {
                  'count': widget.sold,
                }),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s4),

              if (widget.candidates.isEmpty)
                Text(
                  context.t('console.protectionAsk.none'),
                  style: kilo.text.body.copyWith(color: kilo.color.danger),
                )
              else
                for (final trip in widget.candidates)
                  Padding(
                    padding: EdgeInsets.only(bottom: kilo.space.s2),
                    child: _CandidateTile(
                      trip: trip,
                      needed: widget.sold,
                      selected: _departureId == trip.id,
                      onTap: () => setState(() => _departureId = trip.id),
                    ),
                  ),

              if (_departureId != null) ...[
                SizedBox(height: kilo.space.s3),
                KField(
                  label: context.t('console.protectionAsk.note'),
                  helper: context.t('console.protectionAsk.noteHint'),
                  controller: _note,
                  maxLength: 120,
                ),
                SizedBox(height: kilo.space.s2),
                // Said next to the button, not in a notice afterwards. The
                // whole risk of this screen is a dispatcher believing the
                // passengers are placed and going back inside.
                Text(
                  context.t('console.protectionAsk.waits'),
                  style: kilo.text.caption.copyWith(color: kilo.color.warning),
                ),
              ],

              SizedBox(height: kilo.space.s4),
              Row(
                children: [
                  Expanded(
                    child: KButton(
                      label: context.t('console.protectionAsk.back'),
                      tone: KButtonTone.secondary,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SizedBox(width: kilo.space.s3),
                  Expanded(
                    child: KButton(
                      label: context.t('console.protectionAsk.confirm'),
                      onPressed: _departureId == null
                          ? null
                          : () => Navigator.of(context).pop(
                              ProtectionDraft(
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

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.trip,
    required this.needed,
    required this.selected,
    required this.onTap,
  });

  final DepartureSummaryDto trip;
  final int needed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    // Coverage per candidate, exactly as option ② shows it: "18 sur 42" is
    // the number a dispatcher acts on next, and doing that arithmetic in
    // their head while forty-two people watch is how people get left behind.
    final covered = trip.seatsAvailable < needed ? trip.seatsAvailable : needed;

    return InkWell(
      onTap: onTap,
      child: KCard(
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected
                  ? kilo.color.brandPrimary
                  : kilo.color.contentSecondary,
            ),
            SizedBox(width: kilo.space.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(trip.operatorName, style: kilo.text.label),
                  SizedBox(height: kilo.space.s1),
                  Text(
                    '${_time(trip.departsAt)} · '
                    '${context.t('console.protectionAsk.seats', {'count': trip.seatsAvailable})}',
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ),
            ),
            KChip(
              context.t('console.protectionAsk.covers', {
                'covered': covered,
                'total': needed,
              }),
              tone: covered >= needed ? KChipTone.success : KChipTone.warning,
            ),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime instant) {
    // Congo is UTC+1 and does not observe daylight saving, so the offset is a
    // constant rather than a lookup — the same simplification the board makes,
    // and the same one to revisit the day a second market lands.
    final local = instant.toUtc().add(const Duration(hours: 1));
    return '${local.hour.toString().padLeft(2, '0')}h'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
