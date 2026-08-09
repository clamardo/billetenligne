import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// What a seat is doing, from the renderer's point of view.
enum KSeatState { available, held, sold, blocked, selected }

/// One seat, as the map needs it. Deliberately free of any domain type: a
/// component that knows the wire format cannot be rendered in a gallery or a
/// golden test.
final class KSeat {
  const KSeat({
    required this.label,
    required this.state,
    this.sectionCode = 'STD',
    this.priceHint,
  });

  final String label;
  final KSeatState state;
  final String sectionCode;

  /// Rendered under the label when a seat costs more than its neighbours.
  /// Absent for the ordinary case, so a plain coach stays quiet.
  final String? priceHint;
}

/// One cabin section — a block of rows with a fixed abreast pattern.
///
/// This is the abstraction that lets one component draw a 2+2 coach, a
/// VIP-front coach with a 5-across rear bench, and a two-class aircraft, with
/// no special cases anywhere (ADR-0017).
final class KSection {
  const KSection({
    required this.code,
    required this.label,
    required this.abreast,
    this.pitchCm,
  });

  final String code;
  final String label;

  /// `2+2`, `2+3`, `1+2`, `5`. Each group is a block of seats; `+` is an
  /// aisle.
  final String abreast;

  final int? pitchCm;

  List<int> get blocks =>
      abreast.split('+').map((p) => int.tryParse(p.trim()) ?? 0).toList();

  int get seatsPerRow => blocks.fold(0, (a, b) => a + b);
}

/// The words the map needs.
///
/// Passed in rather than defaulted, because `bel_design` holds no user-facing
/// strings at all — every one of these comes from the translation catalog, and
/// a French default here is a French string that would eventually ship to an
/// English reader.
final class KSeatMapLabels {
  const KSeatMapLabels({
    required this.front,
    required this.free,
    required this.chosen,
    required this.taken,
  });

  final String front;
  final String free;
  final String chosen;
  final String taken;
}

/// The seat map.
///
/// A **diagram**, never a photograph. Operators do not have usable photos of
/// their fleet, and a diagram built from the layout they typed is both honest
/// and always current — a photo of last year's coach is worse than no photo.
///
/// Three details carry most of the usability:
///
///   * **The aisle is real space**, not a line. People read a coach by its
///     aisle, and a map that renders one as a hairline reads as a solid block
///     of seats.
///   * **A taken seat is not merely grey.** It gets a slash as well, because
///     grey-versus-green is exactly the distinction that fails in direct sun
///     and for a colour-blind traveller.
///   * **The front of the vehicle is marked.** Without it, half of people
///     assume row 1 is at the back, choose accordingly, and are disappointed.
final class KSeatMap extends StatelessWidget {
  const KSeatMap({
    required this.sections,
    required this.seats,
    required this.selected,
    required this.onToggle,
    required this.labels,
    this.maxSelectable = 6,
    super.key,
  });

  final List<KSection> sections;

  /// In physical order, front to back. The map trusts this order — it is the
  /// order the operator typed, and the labels follow the stickers on the
  /// seats rather than our database.
  final List<KSeat> seats;

  final Set<String> selected;
  final void Function(KSeat seat) onToggle;
  final KSeatMapLabels labels;
  final int maxSelectable;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return LayoutBuilder(
      builder: (context, constraints) {
        final widest = sections.fold(
          0,
          (m, s) => s.seatsPerRow > m ? s.seatsPerRow : m,
        );
        final aisles = sections.fold(
          0,
          (m, s) => (s.blocks.length - 1) > m ? s.blocks.length - 1 : m,
        );

        // Seats shrink to fit the widest row rather than scrolling sideways.
        // A seat map that pans horizontally is a seat map nobody can read on a
        // 5-inch screen.
        final available = constraints.maxWidth - kilo.space.s4 * 2;
        final cell = ((available - aisles * kilo.space.s5) / widest).clamp(
          28.0,
          52.0,
        );

        var offset = 0;
        final blocks = <Widget>[];

        for (final section in sections) {
          final count = _seatCountFor(section);
          final slice = seats.skip(offset).take(count).toList();
          offset += count;
          if (slice.isEmpty) continue;

          blocks
            ..add(_SectionHeader(section: section))
            ..add(
              _SectionGrid(
                section: section,
                seats: slice,
                selected: selected,
                cell: cell,
                onToggle: onToggle,
              ),
            );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FrontMarker(label: labels.front),
            SizedBox(height: kilo.space.s3),
            ...blocks,
            SizedBox(height: kilo.space.s4),
            _Legend(labels: labels),
          ],
        );
      },
    );
  }

  /// Sections do not carry a row count here; the seat list is the truth. Rows
  /// are whatever the seats divide into, which keeps the two from disagreeing
  /// when an operator blocks a seat.
  int _seatCountFor(KSection section) =>
      seats.where((s) => s.sectionCode == section.code).length;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section});
  final KSection section;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: kilo.space.s3),
      child: Row(
        children: [
          Text(
            section.label.toUpperCase(),
            style: kilo.text.label.copyWith(color: kilo.color.contentSecondary),
          ),
          SizedBox(width: kilo.space.s2),
          Expanded(child: Divider(color: kilo.color.borderSubtle, height: 1)),
          if (section.pitchCm != null) ...[
            SizedBox(width: kilo.space.s2),
            Text(
              '${section.pitchCm} cm',
              style: kilo.text.caption.copyWith(color: kilo.color.contentMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionGrid extends StatelessWidget {
  const _SectionGrid({
    required this.section,
    required this.seats,
    required this.selected,
    required this.cell,
    required this.onToggle,
  });

  final KSection section;
  final List<KSeat> seats;
  final Set<String> selected;
  final double cell;
  final void Function(KSeat) onToggle;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final perRow = section.seatsPerRow;
    if (perRow == 0) return const SizedBox.shrink();

    final rows = <Widget>[];
    for (var start = 0; start < seats.length; start += perRow) {
      final rowSeats = seats.skip(start).take(perRow).toList();
      final children = <Widget>[];
      var index = 0;

      for (var b = 0; b < section.blocks.length; b++) {
        for (var i = 0; i < section.blocks[b]; i++) {
          if (index >= rowSeats.length) break;
          final seat = rowSeats[index++];
          children.add(
            Padding(
              padding: EdgeInsets.all(kilo.space.s1 / 2),
              child: _SeatTile(
                seat: seat,
                size: cell,
                isSelected: selected.contains(seat.label),
                onTap: () => onToggle(seat),
              ),
            ),
          );
        }
        // The aisle. Real space, because that is how people read a coach.
        if (b < section.blocks.length - 1) {
          children.add(SizedBox(width: kilo.space.s5));
        }
      }

      rows.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: kilo.space.s1 / 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: children,
          ),
        ),
      );
    }

    return Column(children: rows);
  }
}

class _SeatTile extends StatelessWidget {
  const _SeatTile({
    required this.seat,
    required this.size,
    required this.isSelected,
    required this.onTap,
  });

  final KSeat seat;
  final double size;
  final bool isSelected;
  final VoidCallback onTap;

  bool get _selectable => seat.state == KSeatState.available;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final state = isSelected ? KSeatState.selected : seat.state;

    final (background, foreground, border) = switch (state) {
      KSeatState.available => (
        kilo.color.surfaceRaised,
        kilo.color.contentPrimary,
        kilo.color.borderStrong,
      ),
      KSeatState.selected => (
        kilo.color.brandPrimary,
        kilo.color.onBrandPrimary,
        kilo.color.brandPrimaryStrong,
      ),
      KSeatState.held || KSeatState.sold || KSeatState.blocked => (
        kilo.color.surfaceSunken,
        kilo.color.contentMuted,
        kilo.color.borderSubtle,
      ),
    };

    return Semantics(
      button: _selectable,
      selected: isSelected,
      label: seat.label,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: background,
          borderRadius: BorderRadius.all(kilo.radius.sm),
          child: InkWell(
            onTap: _selectable ? onTap : null,
            borderRadius: BorderRadius.all(kilo.radius.sm),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(kilo.radius.sm),
                border: Border.all(
                  color: border,
                  width: state == KSeatState.selected ? 2 : 1,
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        seat.label,
                        style: kilo.text.amountSm.copyWith(color: foreground),
                      ),
                      if (seat.priceHint != null && size > 40)
                        Text(
                          seat.priceHint!,
                          style: kilo.text.caption.copyWith(
                            color: foreground,
                            fontSize: 9,
                          ),
                        ),
                    ],
                  ),
                  // Not colour alone. Sun flattens hue, and roughly one man in
                  // twelve cannot separate the greys from the greens at all.
                  if (!_selectable)
                    CustomPaint(
                      size: Size(size, size),
                      painter: _SlashPainter(kilo.color.borderStrong),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const inset = 7.0;
    canvas.drawLine(
      Offset(inset, size.height - inset),
      Offset(size.width - inset, inset),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SlashPainter old) => old.color != color;
}

class _FrontMarker extends StatelessWidget {
  const _FrontMarker({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    // Without this, half of people assume row 1 is at the back, choose
    // accordingly, and are disappointed when they board.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(child: Divider(color: kilo.color.borderSubtle)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: kilo.space.s3),
          child: Row(
            children: [
              Icon(
                Icons.arrow_upward,
                size: 14,
                color: kilo.color.contentMuted,
              ),
              SizedBox(width: kilo.space.s1),
              Text(
                label,
                style: kilo.text.label.copyWith(color: kilo.color.contentMuted),
              ),
            ],
          ),
        ),
        Expanded(child: Divider(color: kilo.color.borderSubtle)),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.labels});
  final KSeatMapLabels labels;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    Widget swatch(Color fill, Color border, {bool slashed = false}) => SizedBox(
      width: 16,
      height: 16,
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: border),
              borderRadius: BorderRadius.all(kilo.radius.sm),
            ),
          ),
          if (slashed)
            CustomPaint(
              size: const Size(16, 16),
              painter: _SlashPainter(kilo.color.borderStrong),
            ),
        ],
      ),
    );

    return DefaultTextStyle(
      style: kilo.text.caption.copyWith(color: kilo.color.contentSecondary),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: kilo.space.s4,
        runSpacing: kilo.space.s2,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              swatch(kilo.color.surfaceRaised, kilo.color.borderStrong),
              SizedBox(width: kilo.space.s1),
              Text(labels.free),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              swatch(kilo.color.brandPrimary, kilo.color.brandPrimaryStrong),
              SizedBox(width: kilo.space.s1),
              Text(labels.chosen),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              swatch(
                kilo.color.surfaceSunken,
                kilo.color.borderSubtle,
                slashed: true,
              ),
              SizedBox(width: kilo.space.s1),
              Text(labels.taken),
            ],
          ),
        ],
      ),
    );
  }
}
