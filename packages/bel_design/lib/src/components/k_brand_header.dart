import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../kilo_theme.dart';
import '../tokens/kilo_colors.dart';

/// The three header patterns an operator may choose (`03-operator-lifecycle.md`
/// §2.4).
///
/// **Generated vectors, not images.** Each one paints in about a kilobyte of
/// instructions and themes itself to the accent, which is the whole reason
/// there are three of them and no photography: a cover photo is 120 KB on a
/// metered prepaid bundle, and most operators have no usable photography at
/// all. A storefront that looks empty without one is a broken design
/// (ADR-0009).
enum HeaderPattern {
  flat,
  diagonale,
  vagues;

  static HeaderPattern byName(String? raw) {
    for (final pattern in values) {
      if (pattern.name == raw) return pattern;
    }
    return flat;
  }
}

/// An operator's storefront hero: their mark, their title, their tagline.
///
/// Rendered by the same widget in three places — the storefront page, the
/// console's own header, and the live preview in the vitrine editor — because
/// the preview is the point of that screen. An operator has to see exactly
/// what a customer will see *before* saving, and a preview drawn by a second
/// widget is a preview that will eventually lie (ADR-0004).
///
/// The accent is bounded to [AccentHue], never a free colour: every hue here
/// is verified against `contentPrimary`, `surfaceRaised` and plein soleil.
final class KBrandHeader extends StatelessWidget {
  const KBrandHeader({
    required this.title,
    required this.accent,
    this.tagline,
    this.pattern = HeaderPattern.flat,
    this.logo,
    this.footnote,
    this.compact = false,
    super.key,
  });

  final String title;
  final String? tagline;
  final AccentHue accent;
  final HeaderPattern pattern;

  /// The operator's own mark, when they have uploaded one. Null falls back to
  /// [KMonogram] — a generated tile rather than an empty square, so an
  /// operator who never opened this screen still looks maintained rather than
  /// abandoned.
  final Widget? logo;

  /// Reliability, usually: `★ 4,2 · 92% à l'heure`. Rendered by the caller,
  /// because the design system holds no business rules.
  final String? footnote;

  /// The console header wears this at half height. One component, two
  /// densities (ADR-0010 rule 10).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final height = compact ? 72.0 : 168.0;

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _PatternPainter(pattern: pattern, accent: accent.color),
          ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: kilo.space.s4,
              vertical: compact ? kilo.space.s2 : kilo.space.s4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: compact ? 40 : 56,
                  height: compact ? 40 : 56,
                  child:
                      logo ??
                      KMonogram(
                        name: title,
                        accent: accent,
                        size: compact ? 40 : 56,
                      ),
                ),
                SizedBox(width: kilo.space.s3),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: (compact ? kilo.text.h3 : kilo.text.h1)
                            .copyWith(color: _onAccent),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (tagline != null && tagline!.isNotEmpty && !compact)
                        Text(
                          tagline!,
                          style: kilo.text.body.copyWith(color: _onAccent),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (footnote != null && !compact)
                        Padding(
                          padding: EdgeInsets.only(top: kilo.space.s1),
                          child: Text(
                            footnote!,
                            style: kilo.text.caption.copyWith(
                              color: _onAccent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// White, on every one of the eight. That is not a coincidence — it is the
  /// property the closed set exists to have, and it is asserted in the
  /// contrast tests rather than assumed here.
  static const _onAccent = Color(0xFFFFFFFF);
}

/// A generated tile for an operator with no logo.
///
/// Up to two initials over the accent. The documented default of
/// `03-operator-lifecycle.md` §2.4: "an operator can complete onboarding
/// without ever opening this step and still look maintained rather than
/// abandoned."
final class KMonogram extends StatelessWidget {
  const KMonogram({
    required this.name,
    required this.accent,
    this.size = 56,
    super.key,
  });

  final String name;
  final AccentHue accent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: kilo.radius.controlBorder,
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style: kilo.text.h3.copyWith(
          color: accent.color,
          fontSize: size * 0.38,
          height: 1,
        ),
      ),
    );
  }

  /// `Océan du Nord SARL` → `ON`. Skips the words that carry no identity:
  /// every second operator in Congo is a `SARL`, and a monogram reading `OS`
  /// identifies nobody.
  static String initialsOf(String name) {
    const skip = {'sarl', 'sa', 'sas', 'ltd', 'du', 'de', 'des', 'la', 'le'};
    final words = name
        .split(RegExp(r'[\s\-]+'))
        .where((w) => w.isNotEmpty && !skip.contains(w.toLowerCase()))
        .toList();
    if (words.isEmpty) return name.isEmpty ? '?' : name[0].toUpperCase();
    if (words.length == 1) {
      final word = words.first;
      return (word.length == 1 ? word : word.substring(0, 2)).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }
}

/// Flat, diagonal stripes, or waves — painted, never fetched.
class _PatternPainter extends CustomPainter {
  const _PatternPainter({required this.pattern, required this.accent});

  final HeaderPattern pattern;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = accent);
    if (pattern == HeaderPattern.flat) return;

    // A tenth of an alpha over the accent itself: visible enough to read as
    // texture, faint enough that the title stays at the contrast ratio the
    // hue was chosen for. A pattern that eats its own header is worse than no
    // pattern.
    final ink = Paint()
      ..color = const Color(0x1AFFFFFF)
      ..style = PaintingStyle.fill;

    switch (pattern) {
      case HeaderPattern.diagonale:
        const step = 28.0;
        for (var x = -size.height; x < size.width; x += step * 2) {
          canvas.drawPath(
            Path()
              ..moveTo(x, size.height)
              ..lineTo(x + size.height, 0)
              ..lineTo(x + size.height + step, 0)
              ..lineTo(x + step, size.height)
              ..close(),
            ink,
          );
        }
      case HeaderPattern.vagues:
        const amplitude = 10.0;
        for (var band = 0; band < 3; band++) {
          final baseline = size.height * (0.45 + band * 0.22);
          final path = Path()..moveTo(0, baseline);
          for (var x = 0.0; x <= size.width; x += 4) {
            path.lineTo(
              x,
              baseline + math.sin((x / size.width) * math.pi * 4) * amplitude,
            );
          }
          path
            ..lineTo(size.width, size.height)
            ..lineTo(0, size.height)
            ..close();
          canvas.drawPath(path, ink);
        }
      case HeaderPattern.flat:
        break;
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.pattern != pattern || old.accent != accent;
}
