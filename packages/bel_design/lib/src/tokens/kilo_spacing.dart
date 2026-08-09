import 'package:flutter/widgets.dart';

/// A 4 pt scale. There is no `EdgeInsets.all(13)` in this codebase
/// (ADR-0010 rule 4).
@immutable
final class KiloSpacing {
  const KiloSpacing();

  double get s1 => 4;
  double get s2 => 8;
  double get s3 => 12;
  double get s4 => 16;
  double get s5 => 20;
  double get s6 => 24;
  double get s8 => 32;
  double get s10 => 40;
  double get s12 => 48;
  double get s16 => 64;

  /// Screen gutter — 16 on mobile, 24 from tablet up.
  double gutter(double width) => width >= 600 ? s6 : s4;

  /// Minimum touch target. 48 dp, no exceptions: gloves, cracked digitisers,
  /// moving buses (`05-design-system.md` §9).
  double get touchTarget => 48;
}

@immutable
final class KiloRadius {
  const KiloRadius();

  Radius get sm => const Radius.circular(8);
  Radius get md => const Radius.circular(12);
  Radius get lg => const Radius.circular(16);
  Radius get xl => const Radius.circular(24);
  Radius get pill => const Radius.circular(999);

  /// The cut-out on a ticket stub.
  Radius get notch => const Radius.circular(12);

  BorderRadius get cardBorder => BorderRadius.all(lg);
  BorderRadius get controlBorder => BorderRadius.all(md);
}

/// Three levels, and borders do most of the work: soft shadows render poorly
/// and cost fill-rate on cheap GPUs, so every raised surface pairs a 1 px
/// border with a minimal shadow and still reads correctly if the shadow is
/// imperceptible.
@immutable
final class KiloElevation {
  const KiloElevation(this._shadowColor);
  final Color _shadowColor;

  List<BoxShadow> get flat => const [];

  List<BoxShadow> get raised => [
    BoxShadow(
      color: _shadowColor.withValues(alpha: 0.06),
      offset: const Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  List<BoxShadow> get floating => [
    BoxShadow(
      color: _shadowColor.withValues(alpha: 0.14),
      offset: const Offset(0, 8),
      blurRadius: 24,
    ),
  ];
}

/// Ceiling 300 ms, and most things are 160 ms. Nothing loops, nothing
/// parallaxes, nothing decorates. On a 2 GB device motion is a battery tax
/// paid by the poorest user.
@immutable
final class KiloMotion {
  const KiloMotion();

  Duration get micro => const Duration(milliseconds: 120);
  Duration get standard => const Duration(milliseconds: 200);
  Duration get emphasis => const Duration(milliseconds: 300);

  Curve get curve => Curves.easeOutCubic;
  Curve get microCurve => Curves.easeOut;

  /// Every animation respects the platform's reduce-motion setting.
  Duration resolve(Duration base, {required bool animationsDisabled}) =>
      animationsDisabled ? Duration.zero : base;
}
