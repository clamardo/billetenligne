import 'package:flutter/widgets.dart';

/// Which of the three Kilo themes a palette represents.
///
/// [pleinSoleil] is not a nicety. A conductor validating sixty tickets in
/// direct equatorial sun on a scratched 720p panel is our least forgiving
/// user, and the one whose failure is most visible (`05-design-system.md`
/// §2.3). It is the default in conductor mode.
enum KiloBrightness { light, dark, pleinSoleil }

/// Semantic colour tokens. Application code names *meaning*, never a hue —
/// `content.muted`, never `#7A857F` and never `grey500`. That is what makes
/// dark mode a token swap rather than a per-widget audit (ADR-0010 rule 3).
@immutable
final class KiloColors {
  const KiloColors({
    required this.brightness,
    required this.brandPrimary,
    required this.brandPrimaryStrong,
    required this.brandPrimarySoft,
    required this.onBrandPrimary,
    required this.brandAccent,
    required this.brandAccentSoft,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.info,
    required this.surfaceBase,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.surfaceOverlay,
    required this.borderSubtle,
    required this.borderStrong,
    required this.contentPrimary,
    required this.contentSecondary,
    required this.contentMuted,
    required this.contentInverse,
  });

  final KiloBrightness brightness;

  // Brand — Forêt & Latérite. Congo's landscape and light, not its flag.
  final Color brandPrimary;
  final Color brandPrimaryStrong;
  final Color brandPrimarySoft;
  final Color onBrandPrimary;
  final Color brandAccent;
  final Color brandAccentSoft;

  // Semantic state. Never the only signal — every state pairs with an icon
  // and a word, for colour-blind users and for cheap panels alike.
  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;
  final Color info;

  // Neutrals, warm-tinted: a cold grey ramp reads clinical and cheap on
  // low-gamut screens.
  final Color surfaceBase;
  final Color surfaceRaised;
  final Color surfaceSunken;
  final Color surfaceOverlay;
  final Color borderSubtle;
  final Color borderStrong;
  final Color contentPrimary;
  final Color contentSecondary;
  final Color contentMuted;
  final Color contentInverse;

  static const light = KiloColors(
    brightness: KiloBrightness.light,
    brandPrimary: Color(0xFF0A6B4F),
    brandPrimaryStrong: Color(0xFF075440),
    brandPrimarySoft: Color(0xFFE4F1EB),
    onBrandPrimary: Color(0xFFFFFFFF),
    brandAccent: Color(0xFFD9772F),
    brandAccentSoft: Color(0xFFFBEEE2),
    success: Color(0xFF0F7350),
    successSoft: Color(0xFFE2F3EC),
    warning: Color(0xFF8F5800),
    warningSoft: Color(0xFFFDF1DC),
    danger: Color(0xFFB3332B),
    dangerSoft: Color(0xFFFBE9E7),
    info: Color(0xFF1F5FA8),
    surfaceBase: Color(0xFFFCFAF7),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF2EEE8),
    surfaceOverlay: Color(0x8C0D110F),
    borderSubtle: Color(0xFFE8E2D9),
    borderStrong: Color(0xFFCFC7BA),
    contentPrimary: Color(0xFF141A17),
    contentSecondary: Color(0xFF4C5651),
    contentMuted: Color(0xFF7A857F),
    contentInverse: Color(0xFFFCFAF7),
  );

  static const dark = KiloColors(
    brightness: KiloBrightness.dark,
    brandPrimary: Color(0xFF3FBF8F),
    brandPrimaryStrong: Color(0xFF2FA87A),
    brandPrimarySoft: Color(0xFF0E241C),
    onBrandPrimary: Color(0xFF04241A),
    brandAccent: Color(0xFFF0A05C),
    brandAccentSoft: Color(0xFF2A1A0E),
    success: Color(0xFF3FBF8F),
    successSoft: Color(0xFF0C2620),
    warning: Color(0xFFE8A93C),
    warningSoft: Color(0xFF2A2008),
    danger: Color(0xFFF0655A),
    dangerSoft: Color(0xFF2E1210),
    info: Color(0xFF6BA6E8),
    surfaceBase: Color(0xFF0D110F),
    surfaceRaised: Color(0xFF161B18),
    surfaceSunken: Color(0xFF090C0A),
    surfaceOverlay: Color(0xA6000000),
    borderSubtle: Color(0xFF242B27),
    borderStrong: Color(0xFF38423C),
    contentPrimary: Color(0xFFF2F5F3),
    contentSecondary: Color(0xFFA8B3AD),
    contentMuted: Color(0xFF78837D),
    contentInverse: Color(0xFF0D110F),
  );

  /// Maximum contrast for direct sunlight. Pure black on pure white, borders
  /// at full strength, states at full saturation.
  static const pleinSoleil = KiloColors(
    brightness: KiloBrightness.pleinSoleil,
    brandPrimary: Color(0xFF00553A),
    brandPrimaryStrong: Color(0xFF003D29),
    brandPrimarySoft: Color(0xFFFFFFFF),
    onBrandPrimary: Color(0xFFFFFFFF),
    brandAccent: Color(0xFFA8460E),
    brandAccentSoft: Color(0xFFFFFFFF),
    success: Color(0xFF00662F),
    successSoft: Color(0xFFFFFFFF),
    warning: Color(0xFF7A4A00),
    warningSoft: Color(0xFFFFFFFF),
    danger: Color(0xFF8E0F07),
    dangerSoft: Color(0xFFFFFFFF),
    info: Color(0xFF0B3F7A),
    surfaceBase: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFFFFFFF),
    surfaceOverlay: Color(0xD9000000),
    borderSubtle: Color(0xFF000000),
    borderStrong: Color(0xFF000000),
    contentPrimary: Color(0xFF000000),
    contentSecondary: Color(0xFF000000),
    contentMuted: Color(0xFF3A3A3A),
    contentInverse: Color(0xFFFFFFFF),
  );

  static KiloColors of(KiloBrightness brightness) => switch (brightness) {
    KiloBrightness.light => light,
    KiloBrightness.dark => dark,
    KiloBrightness.pleinSoleil => pleinSoleil,
  };
}

/// The eight curated accent hues an operator may choose from
/// (`05-design-system.md` §10).
///
/// A closed set, not a colour picker. Every hue is verified against
/// `contentPrimary`, `surfaceRaised` and the plein-soleil theme. A free picker
/// guarantees that some operator eventually chooses a yellow that is invisible
/// in direct sun — and it would be invisible on *our* ticket, in *our* app, at
/// the moment a conductor needs to read it.
enum AccentHue {
  foret(Color(0xFF0A6B4F)),
  laterite(Color(0xFFD9772F)),
  indigo(Color(0xFF1E3A6B)),
  brique(Color(0xFFB4502E)),
  prune(Color(0xFF6B2D5C)),
  ocean(Color(0xFF0E5E75)),
  olive(Color(0xFF54661F)),
  ardoise(Color(0xFF3B4650));

  const AccentHue(this.color);
  final Color color;

  /// Falls back to the house hue rather than throwing. An accent that fails
  /// to parse is a storefront that should still render — the row came from a
  /// database column with a CHECK constraint, and if it ever disagrees with
  /// this enum the honest failure is a green header, not a blank screen.
  static AccentHue byName(String? raw) {
    for (final hue in values) {
      if (hue.name == raw) return hue;
    }
    return foret;
  }
}
