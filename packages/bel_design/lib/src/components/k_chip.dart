import 'package:flutter/widgets.dart';

import '../kilo_theme.dart';

enum KChipTone { neutral, brand, success, warning, danger }

/// A small status marker.
///
/// **Never colour alone.** Every chip carries a label, and the tone only
/// reinforces it. Direct sun flattens hue, and about one man in twelve cannot
/// separate red from green at all — a conductor among them still has to read
/// the screen.
final class KChip extends StatelessWidget {
  const KChip(
    this.label, {
    this.tone = KChipTone.neutral,
    this.icon,
    super.key,
  });

  final String label;
  final KChipTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final (background, foreground) = switch (tone) {
      KChipTone.neutral => (
        kilo.color.surfaceSunken,
        kilo.color.contentSecondary,
      ),
      KChipTone.brand => (
        kilo.color.brandPrimarySoft,
        kilo.color.brandPrimaryStrong,
      ),
      KChipTone.success => (kilo.color.successSoft, kilo.color.success),
      KChipTone.warning => (kilo.color.warningSoft, kilo.color.warning),
      KChipTone.danger => (kilo.color.dangerSoft, kilo.color.danger),
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: kilo.space.s2,
        vertical: kilo.space.s1,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.all(kilo.radius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            SizedBox(width: kilo.space.s1),
          ],
          // Flexible, so a chip narrows instead of overflowing its row. The
          // French string fits; the English one is a third longer, and a
          // label an operator typed is any length at all. A row that breaks
          // on a long word is a row that breaks in exactly the language we
          // test least.
          Flexible(
            child: Text(
              label,
              style: kilo.text.caption.copyWith(color: foreground),
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
