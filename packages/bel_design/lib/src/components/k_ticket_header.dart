import 'package:flutter/material.dart';

import '../art/kilo_pattern.dart';
import '../kilo_theme.dart';

/// The top of a ticket: the operator's colour, their woven motif, the two
/// towns, and a torn edge.
///
/// The ticket is the one screen a passenger holds up to another human being,
/// and it opened on two lines of centred grey text. A paper ticket is
/// instantly recognisable from across a yard; this is the cheapest way to buy
/// back some of that — the company's own colour across the top, their motif
/// woven into it, the journey in display type, and a perforation to say
/// *this is a ticket* before anybody has read a word.
///
/// The perforation is drawn, not clipped. A clipped notch has to know the
/// colour of whatever is behind it, which on a scrolling screen with a
/// disruption strip above it is not a colour anybody can promise.
final class KTicketHeader extends StatelessWidget {
  const KTicketHeader({
    required this.origin,
    required this.destination,
    super.key,
    this.subtitle,
    this.footnote,
    this.accent,
    this.motif = KPatternMotif.kuba,
    this.trailing,
  });

  final String origin;
  final String destination;
  final String? subtitle;
  final String? footnote;

  /// The operator's own hue. Falls back to the house green, which is what an
  /// operator who has never opened the vitrine gets — and it must still look
  /// deliberate, because that is most of them on day one.
  final Color? accent;
  final KPatternMotif motif;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final colour = accent ?? kilo.color.brandPrimary;
    // Not `onBrandPrimary`: the accent is one of eight curated hues, and the
    // set is chosen so white carries on all of them.
    const ink = Color(0xFFFFFFFF);

    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: kilo.radius.lg),
      child: DecoratedBox(
        decoration: BoxDecoration(color: colour),
        child: Stack(
          children: [
            Positioned.fill(
              child: KPattern(
                motif: motif,
                color: ink,
                opacity: 0.11,
                scale: 0.85,
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                kilo.space.s5,
                kilo.space.s5,
                kilo.space.s5,
                kilo.space.s6,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$origin → $destination',
                          style: kilo.text.h1.copyWith(color: ink),
                        ),
                        if (subtitle != null) ...[
                          SizedBox(height: kilo.space.s1),
                          Text(
                            subtitle!,
                            style: kilo.text.body.copyWith(
                              color: ink.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                        if (footnote != null) ...[
                          SizedBox(height: kilo.space.s1),
                          Text(
                            footnote!,
                            style: kilo.text.bodySm.copyWith(
                              color: ink.withValues(alpha: 0.78),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    SizedBox(width: kilo.space.s3),
                    IconTheme(
                      data: const IconThemeData(color: ink),
                      child: DefaultTextStyle(
                        style: kilo.text.bodySm.copyWith(color: ink),
                        child: trailing!,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 14,
              child: CustomPaint(painter: _Perforation(ink)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Perforation extends CustomPainter {
  const _Perforation(this.ink);
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()
      ..color = ink.withValues(alpha: 0.42)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // The two half-circles are the tear, and they are painted rather than
    // cut: a cut-out has to know the colour behind it, and on a screen that
    // scrolls under a disruption strip nobody can promise one.
    final notch = Paint()..color = ink.withValues(alpha: 0.22);
    canvas.drawCircle(Offset(0, y), 7, notch);
    canvas.drawCircle(Offset(size.width, y), 7, notch);

    for (var x = 12.0; x < size.width - 12; x += 10) {
      canvas.drawLine(Offset(x, y), Offset(x + 4, y), line);
    }
  }

  @override
  bool shouldRepaint(_Perforation old) => old.ink != ink;
}
