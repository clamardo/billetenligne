import 'package:flutter/material.dart';

import 'tokens/kilo_colors.dart';
import 'tokens/kilo_spacing.dart';
import 'tokens/kilo_typography.dart';

/// Component density. The same components render at [comfortable] on mobile
/// and [compact] in console tables — one component set, two densities
/// (ADR-0010 rule 10), never two parallel component libraries.
enum KiloDensity { comfortable, compact }

/// Kilo rides *on top of* Material 3 rather than replacing it, so we keep
/// accessibility, focus handling and platform behaviour for free and override
/// only appearance (ADR-0010 rule 2).
@immutable
final class KiloTheme extends ThemeExtension<KiloTheme> {
  KiloTheme({required this.color, this.density = KiloDensity.comfortable})
    : text = KiloTypography(color.contentPrimary),
      space = const KiloSpacing(),
      radius = const KiloRadius(),
      motion = const KiloMotion(),
      elevation = KiloElevation(color.contentPrimary);

  final KiloColors color;
  final KiloDensity density;
  final KiloTypography text;
  final KiloSpacing space;
  final KiloRadius radius;
  final KiloMotion motion;
  final KiloElevation elevation;

  /// Row height and control padding shrink in the console; touch targets on
  /// mobile never do.
  double get rowHeight =>
      density == KiloDensity.compact ? 40 : space.touchTarget;

  @override
  KiloTheme copyWith({KiloColors? color, KiloDensity? density}) =>
      KiloTheme(color: color ?? this.color, density: density ?? this.density);

  /// Themes are discrete, not interpolated: cross-fading between light and
  /// dark mid-animation produces muddy intermediate colours that pass no
  /// contrast check. Snap at the halfway point instead.
  @override
  KiloTheme lerp(ThemeExtension<KiloTheme>? other, double t) {
    if (other is! KiloTheme) return this;
    return t < 0.5 ? this : other;
  }

  static ThemeData materialTheme({
    KiloBrightness brightness = KiloBrightness.light,
    KiloDensity density = KiloDensity.comfortable,
  }) {
    final colors = KiloColors.of(brightness);
    final kilo = KiloTheme(color: colors, density: density);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness == KiloBrightness.dark
          ? Brightness.dark
          : Brightness.light,
      scaffoldBackgroundColor: colors.surfaceBase,
      fontFamily: KiloTypography.family,
      colorScheme: ColorScheme(
        brightness: brightness == KiloBrightness.dark
            ? Brightness.dark
            : Brightness.light,
        primary: colors.brandPrimary,
        onPrimary: colors.onBrandPrimary,
        secondary: colors.brandAccent,
        onSecondary: colors.contentInverse,
        error: colors.danger,
        onError: colors.contentInverse,
        surface: colors.surfaceRaised,
        onSurface: colors.contentPrimary,
      ),
      extensions: [kilo],
    );
  }
}

/// `context.kilo.color.brandPrimary` — the only way application code reaches a
/// token. A raw `Color(0x…)` or a magic `EdgeInsets` number outside this
/// package is a build failure, not a review comment (ADR-0010 rule 1).
extension KiloThemeContext on BuildContext {
  KiloTheme get kilo =>
      Theme.of(this).extension<KiloTheme>() ??
      KiloTheme(color: KiloColors.light);
}
