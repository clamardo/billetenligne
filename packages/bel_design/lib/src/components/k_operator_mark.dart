import 'package:flutter/material.dart';

import '../kilo_theme.dart';
import '../tokens/kilo_colors.dart';
import 'k_brand_header.dart';

/// A company's mark, at the size a list row can spare.
///
/// A results row is a choice **between companies**, and a company somebody
/// cannot recognise is a company they cannot choose. Congo's coach market
/// runs on names heard at a station and marks seen on an agency door, so the
/// mark is often what a traveller is actually looking for on the row.
///
/// **It always draws something.** The uploaded logo when there is one, the
/// generated monogram when there is not, and the monogram again the moment
/// the image fails — which on this market's connections is an ordinary
/// afternoon, not an error. A row whose mark did not load is a row, not a
/// broken square (§7.1).
///
/// **The image is never trusted with the layout.** It is boxed to [size] and
/// cropped, because what arrives is a file an operator uploaded: a 4:1 banner
/// or a 2000 px square would otherwise decide how tall the row is.
final class KOperatorMark extends StatelessWidget {
  const KOperatorMark({
    required this.name,
    required this.accent,
    this.logoUrl,
    this.size = 32,
    super.key,
  });

  /// The company's own name — what the monogram is generated from, and what a
  /// screen reader says whether or not the image arrived.
  final String name;

  /// Bounded to [AccentHue] rather than a free colour: every hue here is
  /// verified against the contrast gate, and a logo-less row is drawn in one.
  final AccentHue accent;

  final String? logoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    // Filled: at this size the initials are small copy, and the hue on white
    // is not always readable. See [KMonogram.filled].
    final fallback = KMonogram(
      name: name,
      accent: accent,
      size: size,
      filled: true,
    );
    final url = logoUrl;

    return Semantics(
      label: name,
      image: url != null,
      child: SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: kilo.radius.controlBorder,
          child: url == null
              ? fallback
              : Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  // The monogram, not a broken square and not a spinner. A
                  // row that spun while its logo loaded would flicker eleven
                  // times on one screen, and the mark is not what anybody is
                  // waiting for.
                  errorBuilder: (_, _, _) => fallback,
                  frameBuilder: (_, child, frame, wasSync) =>
                      frame == null && !wasSync ? fallback : child,
                ),
        ),
      ),
    );
  }
}
