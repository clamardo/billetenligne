import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// Which coach goes out instead — option ① of `08-disruption.md` §2.2.
///
/// The commonest resolution to a breakdown in this market: the operator's
/// spare, or a coach pulled off a quieter duty. The bookings do not move, the
/// passengers keep their journey, and the seats are remapped onto whatever
/// the new coach actually has.
///
/// Two things this screen does that a bare dropdown would not:
///
///   * **It says how many seats each coach has, against how many are sold.**
///     A dispatcher choosing under pressure should not have to remember that
///     the 33-seater cannot take a full 49 — and a coach that is too small is
///     shown as too small rather than offered and then refused by the server.
///   * **It warns that seats will change.** Every passenger already has a QR
///     with a seat number on it; a swap re-signs all of them, and forty-two
///     people are about to receive a message saying so.
final class RescueSheet extends StatefulWidget {
  const RescueSheet({
    required this.routeCode,
    required this.sold,
    required this.coaches,
    this.currentVehicle,
    super.key,
  });

  final String routeCode;

  /// Confirmed passengers. Every one of them has to fit.
  final int sold;

  final List<VehicleDto> coaches;

  /// What is on the departure now, if anything. Shown so a dispatcher can see
  /// what they are replacing rather than having to remember it.
  final String? currentVehicle;

  @override
  State<RescueSheet> createState() => _RescueSheetState();
}

/// What the sheet answers with. Null when it was dismissed.
final class RescueDraft {
  const RescueDraft({required this.vehicleId, this.note});

  final String vehicleId;
  final String? note;
}

class _RescueSheetState extends State<RescueSheet> {
  String? _vehicleId;
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
                context.t('console.rescue.title', {
                  'vehicle':
                      widget.currentVehicle ??
                      context.t('console.today.noVehicle'),
                }),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s4),

              if (widget.coaches.isEmpty)
                // Names the cause rather than showing an empty list. An
                // operator with one coach has no spare, and the answer to a
                // breakdown is then the re-accommodation desk, not this sheet.
                Text(
                  context.t('console.rescue.none'),
                  style: kilo.text.body.copyWith(color: kilo.color.danger),
                )
              else
                for (final coach in widget.coaches)
                  Padding(
                    padding: EdgeInsets.only(bottom: kilo.space.s2),
                    child: _CoachTile(
                      coach: coach,
                      sold: widget.sold,
                      selected: _vehicleId == coach.id,
                      onTap: () => setState(() => _vehicleId = coach.id),
                    ),
                  ),

              if (_vehicleId != null) ...[
                SizedBox(height: kilo.space.s3),
                KField(
                  label: context.t('console.rescue.note'),
                  helper: context.t('console.rescue.noteHint'),
                  controller: _note,
                  maxLength: 120,
                ),
                SizedBox(height: kilo.space.s4),
                // Said before the button. Every passenger holds a QR with a
                // seat number on it, and this is what makes those obsolete.
                Text(
                  context.t('console.rescue.willMove', {'count': widget.sold}),
                  style: kilo.text.bodySm,
                ),
              ],

              SizedBox(height: kilo.space.s4),
              Row(
                children: [
                  Expanded(
                    child: KButton(
                      label: context.t('console.rescue.back'),
                      tone: KButtonTone.secondary,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SizedBox(width: kilo.space.s3),
                  Expanded(
                    child: KButton(
                      label: context.t('console.rescue.confirm'),
                      onPressed: _vehicleId == null
                          ? null
                          : () => Navigator.of(context).pop(
                              RescueDraft(
                                vehicleId: _vehicleId!,
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

/// One coach, and whether everybody fits in it.
class _CoachTile extends StatelessWidget {
  const _CoachTile({
    required this.coach,
    required this.sold,
    required this.selected,
    required this.onTap,
  });

  final VehicleDto coach;
  final int sold;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    // The server refuses a coach that cannot seat everybody, and it is right
    // to. Refusing it here as well means the dispatcher finds out while they
    // are still choosing rather than after they have committed.
    final short = sold - coach.capacity;
    final fits = short <= 0;

    return InkWell(
      onTap: fits ? onTap : null,
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    coach.nickname ?? coach.registration,
                    style: kilo.text.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    coach.layoutName,
                    style: kilo.text.caption.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            SizedBox(width: kilo.space.s2),
            if (fits)
              KChip(
                context.t('console.rescue.seats', {'count': coach.capacity}),
                tone: KChipTone.success,
              )
            else
              KChip(
                context.t('console.rescue.short', {'count': short}),
                tone: KChipTone.danger,
              ),
          ],
        ),
      ),
    );
  }
}
