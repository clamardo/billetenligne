import 'package:flutter/material.dart';

import '../art/kilo_pattern.dart';
import '../kilo_theme.dart';

/// The brand ground a back-office navigation rail stands on.
///
/// The console and the back office are tables of numbers on a pale ground,
/// which is right — an operator reads this all day, and a tinted table is a
/// harder table to read. The cost was that nineteen screens between them drew
/// no part of the design system's artwork at all, so both surfaces looked
/// like a wireframe of themselves. One green column carries the identity for
/// every screen behind it and takes nothing from the working area.
///
/// **A skin, not a rail.** It wraps whatever `NavigationRail` the app already
/// builds — the destinations, the badges and the trailing controls stay the
/// app's business — and supplies only the appearance, through
/// `NavigationRailTheme` rather than per-property arguments the two shells
/// would then have to keep in step by hand.
///
/// Three inheritance paths, because Flutter has three:
///   * `NavigationRailTheme` for the destinations and the indicator;
///   * `IconTheme` for plain `Icon`s in the leading and trailing slots;
///   * `IconButtonTheme` because `IconButton` reads its foreground from that
///     and ignores the ambient `IconTheme` — without it the theme toggle,
///     the language menu and the second-factor button keep the default dark
///     ink and vanish into the green.
///
/// The ink is `onBrandPrimary` throughout: the pair the contrast gate already
/// checks against `brandPrimary`, so the motif behind it cannot make a label
/// unreadable.
final class KRailSkin extends StatelessWidget {
  const KRailSkin({
    required this.child,
    this.motif = KPatternMotif.kuba,
    super.key,
  });

  /// The app's own `NavigationRail`.
  final Widget child;

  final KPatternMotif motif;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final ink = kilo.color.onBrandPrimary;
    // Unselected is dimmed rather than given a second colour: two inks on a
    // patterned ground is how neither ends up reading.
    final dimmed = ink.withValues(alpha: 0.78);

    return KPattern(
      motif: motif,
      background: kilo.color.brandPrimary,
      color: ink,
      opacity: 0.1,
      child: IconTheme(
        data: IconThemeData(color: ink),
        child: IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(foregroundColor: ink),
          ),
          child: NavigationRailTheme(
            data: NavigationRailThemeData(
              backgroundColor: Colors.transparent,
              indicatorColor: ink.withValues(alpha: 0.18),
              selectedIconTheme: IconThemeData(color: ink),
              unselectedIconTheme: IconThemeData(color: dimmed),
              selectedLabelTextStyle: kilo.text.label.copyWith(color: ink),
              unselectedLabelTextStyle: kilo.text.label.copyWith(
                color: dimmed,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
