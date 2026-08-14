import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens/kilo_colors.dart';

/// Builds a **complete** Material 3 [ColorScheme] out of Kilo tokens.
///
/// This file exists because of a specific, measurable failure. `ColorScheme`
/// resolves most of its roles lazily, and every fallback collapses onto a
/// role we *were* supplying:
///
/// ```dart
/// Color get primaryContainer        => _primaryContainer ?? primary;
/// Color get surfaceContainer        => _surfaceContainer ?? surface;
/// Color get surfaceContainerHighest => _surfaceContainerHighest ?? surface;
/// Color get outlineVariant          => _outlineVariant ?? onBackground;
/// ```
///
/// Kilo was handing Material eight roles. So every `Card`, `Chip`,
/// `NavigationBar` and `SegmentedButton` in all four apps drew its container
/// in the *same* white as the page behind it, every `Divider` drew in
/// near-black, and every tonal button drew at full brand strength. The product
/// looked like black on white with nothing standing out because, at the
/// framework level, that is exactly what it had been told to be.
///
/// The soft tokens already existed — `brandPrimarySoft`, `surfaceSunken`,
/// `borderSubtle`. They were simply never handed over.
abstract final class KiloScheme {
  /// Relative luminance, so an "on" colour can be *chosen* rather than
  /// assumed. Assuming cost us a real failure: white text on the laterite
  /// accent sat at 3.04:1 in the light theme — legible enough on a desk
  /// monitor, illegible on the phone in the sun this product is built for.
  static double _luminance(Color c) {
    double ch(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  static double _ratio(Color a, Color b) {
    final la = _luminance(a);
    final lb = _luminance(b);
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// Whichever of the two reads better on [on].
  static Color _readable(Color on, Color a, Color b) =>
      _ratio(a, on) >= _ratio(b, on) ? a : b;

  static ColorScheme of(KiloBrightness brightness) {
    final c = KiloColors.of(brightness);
    final isDark = brightness == KiloBrightness.dark;
    final isSun = brightness == KiloBrightness.pleinSoleil;

    // The surface ramp. Material wants five stops; Kilo names three, so the
    // gaps are interpolated rather than invented and the ramp stays
    // monotonic — two adjacent stops that are the same colour are one
    // surface, and that is the bug this whole file exists to prevent.
    //
    // The ramp runs *away* from the reader in light and *towards* them in
    // dark, which is why it is written out per brightness instead of being
    // lerped between two endpoints that mean opposite things.
    //
    // In plein soleil it is deliberately flat: a 4 % tonal step is invisible
    // in direct sun, so separation there comes from full-strength borders.
    final List<Color> ramp;
    if (isSun) {
      ramp = List.filled(5, c.surfaceRaised);
    } else if (isDark) {
      ramp = [
        c.surfaceSunken,
        c.surfaceBase,
        c.surfaceRaised,
        Color.lerp(c.surfaceRaised, c.borderSubtle, 0.6)!,
        c.borderSubtle,
      ];
    } else {
      ramp = [
        c.surfaceRaised,
        c.surfaceBase,
        c.surfaceSunken,
        Color.lerp(c.surfaceSunken, c.borderSubtle, 0.5)!,
        c.borderSubtle,
      ];
    }

    return ColorScheme(
      brightness: isDark ? Brightness.dark : Brightness.light,

      // Brand.
      primary: c.brandPrimary,
      onPrimary: c.onBrandPrimary,
      primaryContainer: c.brandPrimarySoft,
      onPrimaryContainer: isDark ? c.brandPrimary : c.brandPrimaryStrong,
      primaryFixed: c.brandPrimarySoft,
      onPrimaryFixed: c.brandPrimaryStrong,
      primaryFixedDim: c.brandPrimary,
      onPrimaryFixedVariant: c.brandPrimaryStrong,

      secondary: c.brandAccent,
      onSecondary: _readable(c.brandAccent, c.contentInverse, c.contentPrimary),
      secondaryContainer: c.brandAccentSoft,
      // On the pale accent wash a mid-ochre would sit at roughly 3:1 — fine
      // for a 24 px icon, not for the 13 px label that actually goes there.
      onSecondaryContainer: isDark ? c.brandAccent : c.contentPrimary,
      secondaryFixed: c.brandAccentSoft,
      onSecondaryFixed: c.contentPrimary,
      secondaryFixedDim: c.brandAccent,
      onSecondaryFixedVariant: c.contentPrimary,

      tertiary: c.info,
      onTertiary: _readable(c.info, c.contentInverse, c.contentPrimary),
      tertiaryContainer: ramp[2],
      onTertiaryContainer: c.contentPrimary,
      tertiaryFixed: ramp[2],
      onTertiaryFixed: c.contentPrimary,
      tertiaryFixedDim: c.info,
      onTertiaryFixedVariant: c.contentPrimary,

      // State.
      error: c.danger,
      onError: _readable(c.danger, c.contentInverse, c.contentPrimary),
      errorContainer: c.dangerSoft,
      onErrorContainer: c.danger,

      // Surfaces.
      surface: c.surfaceBase,
      onSurface: c.contentPrimary,
      onSurfaceVariant: c.contentSecondary,
      surfaceDim: isSun ? c.surfaceRaised : c.surfaceSunken,
      surfaceBright: isDark ? c.borderSubtle : c.surfaceRaised,
      surfaceContainerLowest: ramp[0],
      surfaceContainerLow: ramp[1],
      surfaceContainer: ramp[2],
      surfaceContainerHigh: ramp[3],
      surfaceContainerHighest: ramp[4],

      // Lines. `outlineVariant` used to fall through to near-black, which is
      // why every divider in the product read as a hard rule.
      outline: c.borderStrong,
      outlineVariant: c.borderSubtle,

      shadow: const Color(0xFF000000),
      scrim: const Color(0xFF000000),

      inverseSurface: c.contentPrimary,
      onInverseSurface: c.contentInverse,
      inversePrimary: isDark
          ? KiloColors.light.brandPrimary
          : KiloColors.dark.brandPrimary,

      // Material tints elevated surfaces with primary. Over a warm neutral
      // ramp that reads as a green cast on white paper, so the ramp above is
      // the only thing that expresses elevation.
      surfaceTint: Colors.transparent,
    );
  }
}
