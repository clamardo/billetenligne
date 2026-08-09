import 'dart:math' as math;

import 'package:bel_design/bel_design.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  // Accessibility is a build gate, not a review comment
  // (`05-design-system.md` §9). The reference viewing condition is direct
  // equatorial sun on a scratched 720p panel — high contrast is the primary
  // functional requirement here, not a checkbox.
  const bodyMin = 4.5;
  const largeMin = 3.0;

  for (final brightness in KiloBrightness.values) {
    final c = KiloColors.of(brightness);

    group('contrast — ${brightness.name}', () {
      void expectContrast(String label, Color fg, Color bg, double min) {
        final ratio = contrastRatio(fg, bg);
        expect(
          ratio,
          greaterThanOrEqualTo(min),
          reason: '$label is ${ratio.toStringAsFixed(2)}:1, needs $min:1',
        );
      }

      test('body text on every surface', () {
        expectContrast(
          'contentPrimary on surfaceBase',
          c.contentPrimary,
          c.surfaceBase,
          bodyMin,
        );
        expectContrast(
          'contentPrimary on surfaceRaised',
          c.contentPrimary,
          c.surfaceRaised,
          bodyMin,
        );
        expectContrast(
          'contentPrimary on surfaceSunken',
          c.contentPrimary,
          c.surfaceSunken,
          bodyMin,
        );
        expectContrast(
          'contentSecondary on surfaceBase',
          c.contentSecondary,
          c.surfaceBase,
          bodyMin,
        );
      });

      test('muted text still clears the large-text floor', () {
        expectContrast(
          'contentMuted on surfaceBase',
          c.contentMuted,
          c.surfaceBase,
          largeMin,
        );
      });

      test('content on the primary action', () {
        expectContrast(
          'onBrandPrimary on brandPrimary',
          c.onBrandPrimary,
          c.brandPrimary,
          largeMin,
        );
      });

      test('the primary action reads against the page', () {
        expectContrast(
          'brandPrimary on surfaceBase',
          c.brandPrimary,
          c.surfaceBase,
          largeMin,
        );
      });

      test('state colours read on their own soft backgrounds', () {
        expectContrast('success', c.success, c.successSoft, bodyMin);
        expectContrast('warning', c.warning, c.warningSoft, bodyMin);
        expectContrast('danger', c.danger, c.dangerSoft, bodyMin);
      });

      test('state colours read on the page', () {
        expectContrast('success on base', c.success, c.surfaceBase, largeMin);
        expectContrast('warning on base', c.warning, c.surfaceBase, largeMin);
        expectContrast('danger on base', c.danger, c.surfaceBase, largeMin);
        expectContrast('info on base', c.info, c.surfaceBase, largeMin);
      });

      test('borders are perceptible', () {
        expectContrast(
          'borderStrong on surfaceRaised',
          c.borderStrong,
          c.surfaceRaised,
          1.4,
        );
      });
    });
  }

  group('operator accent hues — a closed set, verified', () {
    // An operator picks from eight, not from sixteen million
    // (`05-design-system.md` §10). Every one must survive our surfaces,
    // including plein soleil, or a conductor cannot read the ticket band.
    for (final hue in AccentHue.values) {
      test('${hue.name} reads on light and plein soleil surfaces', () {
        expect(
          contrastRatio(hue.color, KiloColors.light.surfaceRaised),
          greaterThanOrEqualTo(3.0),
          reason: '${hue.name} on light surface',
        );
        expect(
          contrastRatio(hue.color, KiloColors.pleinSoleil.surfaceRaised),
          greaterThanOrEqualTo(3.0),
          reason: '${hue.name} in direct sun',
        );
      });

      test('${hue.name} carries white content on a filled band', () {
        expect(
          contrastRatio(const Color(0xFFFFFFFF), hue.color),
          greaterThanOrEqualTo(3.0),
          reason: '${hue.name} band with white text',
        );
      });
    }
  });

  group('plein soleil is genuinely higher contrast', () {
    test('body contrast exceeds the light theme', () {
      final light = contrastRatio(
        KiloColors.light.contentPrimary,
        KiloColors.light.surfaceBase,
      );
      final sun = contrastRatio(
        KiloColors.pleinSoleil.contentPrimary,
        KiloColors.pleinSoleil.surfaceBase,
      );
      expect(sun, greaterThan(light));
      expect(sun, greaterThan(20.0), reason: 'should be near-maximal');
    });
  });
}
