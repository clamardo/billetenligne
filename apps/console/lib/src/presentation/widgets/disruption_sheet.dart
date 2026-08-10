import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';

/// The dispatcher's declaration, in as few taps as it can honestly be made.
///
/// This screen is designed against one constraint from `08-disruption.md`
/// §2.1: it is used at a roadside, on a phone, on 2G, possibly in the rain,
/// while forty-two people watch. Everything follows from that.
///
///   * **Four large targets, not a dropdown.** The kind decides everything
///     downstream, so it is the only thing asked first.
///   * **The new time is chosen in offsets**, not typed into a picker. "+2 h"
///     is one tap; a clock dialog at a roadside is four and a mistake.
///   * **What it will cost is shown before the button, not after.** An hour
///     late entitles every passenger to a free exchange, and a dispatcher
///     should know that at the moment they choose the offset — the threshold
///     comes from the domain rather than from a sentence written here, so the
///     screen cannot drift from what the server will actually do.
final class DisruptionSheet extends StatefulWidget {
  const DisruptionSheet({
    required this.routeCode,
    required this.departsAt,
    required this.sold,
    super.key,
  });

  final String routeCode;
  final DateTime departsAt;

  /// Confirmed passengers. The number that turns "signalé" into a fact the
  /// dispatcher can act on.
  final int sold;

  @override
  State<DisruptionSheet> createState() => _DisruptionSheetState();
}

/// What the sheet answers with. Null when it was dismissed.
final class DisruptionDraft {
  const DisruptionDraft({
    required this.kind,
    required this.cause,
    this.note,
    this.revisedDepartsAt,
  });

  final DisruptionKind kind;
  final DisruptionCause cause;
  final String? note;
  final DateTime? revisedDepartsAt;
}

class _DisruptionSheetState extends State<DisruptionSheet> {
  DisruptionKind? _kind;
  DisruptionCause? _cause;
  Duration? _later;
  final _note = TextEditingController();

  /// The four a dispatcher declares from a roadside. Diversion and route
  /// suspension are real and are not here: both are decided sitting down,
  /// and putting six tiles on this screen makes the four that matter smaller.
  static const _kinds = [
    (DisruptionKind.delay, Icons.schedule),
    (DisruptionKind.breakdownEnRoute, Icons.warning_amber),
    (DisruptionKind.cancellation, Icons.close),
    (DisruptionKind.equipmentSwap, Icons.swap_horiz),
  ];

  static const _offsets = [
    (Duration(minutes: 30), 'plus30'),
    (Duration(minutes: 60), 'plus60'),
    (Duration(minutes: 120), 'plus120'),
    (Duration(minutes: 240), 'plus240'),
  ];

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  bool get _needsTime => _kind == DisruptionKind.delay;

  bool get _canConfirm =>
      _kind != null && _cause != null && (!_needsTime || _later != null);

  /// Asked of the domain, never decided here. The dispatcher is told what
  /// their declaration entitles passengers to before they make it, and the
  /// server will judge it by the same rule.
  bool get _willBeFree =>
      _kind != null &&
      Disruption.stored(
        kind: _kind!,
        cause: _cause ?? DisruptionCause.other,
        departsAt: widget.departsAt,
        declaredAt: widget.departsAt,
        revisedDepartsAt: _later == null ? null : widget.departsAt.add(_later!),
      ).marksInvoluntary;

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
                context.t('console.disruption.title'),
                style: kilo.text.body.copyWith(
                  color: kilo.color.contentSecondary,
                ),
              ),
              SizedBox(height: kilo.space.s4),

              Wrap(
                spacing: kilo.space.s3,
                runSpacing: kilo.space.s3,
                children: [
                  for (final (kind, icon) in _kinds)
                    _KindTile(
                      icon: icon,
                      label: context.t('disruption.kind.${kind.name}'),
                      selected: _kind == kind,
                      onTap: () => setState(() {
                        _kind = kind;
                        if (kind != DisruptionKind.delay) _later = null;
                      }),
                    ),
                ],
              ),

              if (_kind != null) ...[
                SizedBox(height: kilo.space.s4),
                if (_needsTime) ...[
                  Text(
                    context.t('console.disruption.later'),
                    style: kilo.text.caption,
                  ),
                  SizedBox(height: kilo.space.s2),
                  Wrap(
                    spacing: kilo.space.s2,
                    children: [
                      for (final (offset, key) in _offsets)
                        _Choice(
                          label: context.t('console.disruption.$key'),
                          selected: _later == offset,
                          onTap: () => setState(() => _later = offset),
                        ),
                    ],
                  ),
                  SizedBox(height: kilo.space.s4),
                ],

                Text(
                  context.t('console.disruption.cause'),
                  style: kilo.text.caption,
                ),
                SizedBox(height: kilo.space.s2),
                Wrap(
                  spacing: kilo.space.s2,
                  runSpacing: kilo.space.s2,
                  children: [
                    for (final cause in DisruptionCause.values)
                      _Choice(
                        label: context.t('disruption.cause.${cause.name}'),
                        selected: _cause == cause,
                        onTap: () => setState(() => _cause = cause),
                      ),
                  ],
                ),

                SizedBox(height: kilo.space.s4),
                KField(
                  label: context.t('console.disruption.note'),
                  helper: context.t('console.disruption.noteHint'),
                  controller: _note,
                  maxLength: 120,
                ),

                SizedBox(height: kilo.space.s4),
                // Stated before the button and not after it. This is the
                // sentence a dispatcher is accountable for at the counter an
                // hour later.
                Text(
                  context.t('console.disruption.willTell', {
                    'count': widget.sold,
                  }),
                  style: kilo.text.bodySm,
                ),
                Text(
                  context.t(
                    _willBeFree
                        ? 'console.disruption.free'
                        : 'console.disruption.notFree',
                  ),
                  style: kilo.text.bodySm.copyWith(
                    color: _willBeFree
                        ? kilo.color.warning
                        : kilo.color.contentSecondary,
                  ),
                ),
              ],

              SizedBox(height: kilo.space.s4),
              Row(
                children: [
                  Expanded(
                    child: KButton(
                      label: context.t('console.disruption.back'),
                      tone: KButtonTone.secondary,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  SizedBox(width: kilo.space.s3),
                  Expanded(
                    child: KButton(
                      label: context.t('console.disruption.confirm'),
                      onPressed: _canConfirm
                          ? () => Navigator.of(context).pop(
                              DisruptionDraft(
                                kind: _kind!,
                                cause: _cause!,
                                note: _note.text.trim().isEmpty
                                    ? null
                                    : _note.text.trim(),
                                revisedDepartsAt: _later == null
                                    ? null
                                    : widget.departsAt.add(_later!),
                              ),
                            )
                          : null,
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

/// One of the four. Large on purpose — this is pressed with a thumb, by
/// somebody standing up.
class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 148,
        height: 96,
        padding: EdgeInsets.all(kilo.space.s3),
        decoration: BoxDecoration(
          color: selected
              ? kilo.color.brandAccentSoft
              : kilo.color.surfaceRaised,
          border: Border.all(
            color: selected ? kilo.color.brandPrimary : kilo.color.borderSubtle,
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(kilo.space.s2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: kilo.color.contentPrimary),
            SizedBox(height: kilo.space.s2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: kilo.text.bodySm,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: KChip(label, tone: selected ? KChipTone.brand : KChipTone.neutral),
  );
}
