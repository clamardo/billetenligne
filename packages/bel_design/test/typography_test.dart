import 'package:bel_design/bel_design.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The type rules, as assertions rather than as a comment somebody reads once.
///
/// `flutter test` substitutes a fixed-width test font, so nothing here can
/// prove how a glyph looks. What it can prove is the wiring — which family a
/// style names, whether the tabular set is on, and whether the variable axes
/// are actually set — and every one of those has a silent failure mode that
/// presents as "the design looks flat" rather than as an error.
void main() {
  final t = KiloTheme(color: KiloColors.light).text;

  double? axis(TextStyle style, String tag) {
    for (final v in style.fontVariations ?? const <FontVariation>[]) {
      if (v.axis == tag) return v.value;
    }
    return null;
  }

  bool tabular(TextStyle style) => (style.fontFeatures ?? const []).any(
    (f) => f.feature == 'tnum' && f.value == 1,
  );

  group('which face carries what', () {
    test('the display sizes are the serif', () {
      // Fraunces is the reason a page has a voice. If this ever reverts to
      // Inter the product goes back to looking like its own wireframe.
      for (final style in [t.displayXl, t.display, t.h1]) {
        expect(style.fontFamily, KiloTypography.displayFamily);
      }
    });

    test('everything else is Inter', () {
      for (final style in [
        t.h2,
        t.h3,
        t.bodyLg,
        t.body,
        t.bodySm,
        t.caption,
        t.label,
        t.time,
        t.timeHero,
        t.amount,
        t.amountHero,
        t.amountSm,
        t.code,
        t.codeHero,
        t.shout,
      ]) {
        expect(style.fontFamily, KiloTypography.family);
      }
    });

    test('both families are named through the package', () {
      // A bare 'Inter' resolves to nothing and falls back to the platform
      // font without any error at all — which is exactly what happened here
      // for the whole life of the design system before the file existed.
      expect(KiloTypography.family, startsWith('packages/bel_design/'));
      expect(KiloTypography.displayFamily, startsWith('packages/bel_design/'));
    });
  });

  group('numbers', () {
    test('every number style is tabular', () {
      // Amounts that shift width as digits change look untrustworthy, and
      // this product is made entirely of numbers people care about.
      for (final style in [
        t.time,
        t.timeHero,
        t.amount,
        t.amountHero,
        t.amountSm,
        t.code,
        t.codeHero,
      ]) {
        expect(tabular(style), isTrue);
      }
    });

    test('no number style is the serif', () {
      // Fraunces has no tabular set. A booking code where the 1 is narrower
      // than the 8 is a code people misread over a counter.
      for (final style in [t.time, t.timeHero, t.amountHero, t.codeHero]) {
        expect(style.fontFamily, isNot(KiloTypography.displayFamily));
      }
    });

    test('prose is not tabular, because prose is not a column', () {
      expect(tabular(t.body), isFalse);
      expect(tabular(t.h1), isFalse);
    });
  });

  group('the variable axes actually move', () {
    test('weight is set on the axis, not only on fontWeight', () {
      // Flutter does not always map fontWeight onto wght for a variable
      // font, and a weight that silently does nothing is invisible until
      // somebody says the whole design looks flat.
      expect(axis(t.body, 'wght'), 400);
      expect(axis(t.h2, 'wght'), 600);
      expect(axis(t.codeHero, 'wght'), 700);
    });

    test('optical size follows the point size', () {
      // The argument for a variable font over four static weights: a face at
      // 40 px wants different proportions from the same face at 15 px.
      expect(axis(t.displayXl, 'opsz'), 40);
      expect(axis(t.h1, 'opsz'), 26);
      expect(axis(t.body, 'opsz'), 15);
    });

    test('the serif keeps its own two axes', () {
      // SOFT rounds the terminals; WONK turns on the characterful
      // alternates. Without them Fraunces is just another serif.
      expect(axis(t.h1, 'SOFT'), 28);
      expect(axis(t.h1, 'WONK'), 1);
    });

    test('a weight change through the helper moves the axis with it', () {
      final bolder = KiloTypography.weight(t.body, FontWeight.w800);
      expect(bolder.fontWeight, FontWeight.w800);
      expect(axis(bolder, 'wght'), 800);
      // And leaves the other axes alone.
      expect(axis(bolder, 'opsz'), axis(t.body, 'opsz'));
    });

    test('copyWith alone does not, which is why the helper exists', () {
      // Documenting the trap in a test so the next person meets it here
      // rather than on a screen.
      final naive = t.body.copyWith(fontWeight: FontWeight.w800);
      expect(naive.fontWeight, FontWeight.w800);
      expect(axis(naive, 'wght'), 400, reason: 'the axis did not move');
    });
  });
}
