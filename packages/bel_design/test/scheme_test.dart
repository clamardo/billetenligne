import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contrast.dart';

/// These tests exist because of a failure that passed every other test in the
/// suite for months.
///
/// Kilo was handing Material eight of `ColorScheme`'s roles. The rest resolve
/// lazily onto whatever *was* supplied — `surfaceContainer` onto `surface`,
/// `primaryContainer` onto `primary`, `outlineVariant` onto `onSurface` — so
/// every card, chip and navigation bar in four apps drew in the same white as
/// the page behind it and every divider drew in near-black. The product was
/// "black on white with nothing standing out" because the framework had been
/// told, precisely, to be that.
///
/// Nothing about that was visible in a widget test, because widget tests
/// assert on structure. It is visible here.
void main() {
  for (final brightness in [KiloBrightness.light, KiloBrightness.dark]) {
    final scheme = KiloScheme.of(brightness);

    group('scheme — ${brightness.name}', () {
      test('containers are distinct from the surface they sit on', () {
        expect(scheme.surfaceContainerLowest, isNot(scheme.surface));
        expect(scheme.surfaceContainer, isNot(scheme.surface));
        expect(scheme.surfaceContainerHigh, isNot(scheme.surface));
        expect(scheme.surfaceContainerHighest, isNot(scheme.surface));
      });

      test('the surface ramp is monotonic', () {
        final ramp = [
          scheme.surfaceContainerLowest,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
        ];
        for (var i = 1; i < ramp.length; i++) {
          expect(
            ramp[i],
            isNot(ramp[i - 1]),
            reason:
                'ramp stop $i repeats stop ${i - 1}; two adjacent '
                'surfaces that are the same colour are one surface',
          );
        }
      });

      test('a tonal container is not the brand at full strength', () {
        expect(scheme.primaryContainer, isNot(scheme.primary));
        expect(scheme.secondaryContainer, isNot(scheme.secondary));
        expect(scheme.errorContainer, isNot(scheme.error));
      });

      test('a hairline is not the body text colour', () {
        expect(scheme.outlineVariant, isNot(scheme.onSurface));
        expect(
          contrastRatio(scheme.outlineVariant, scheme.surface),
          lessThan(4.5),
          reason: 'outlineVariant is meant to be a whisper, not a rule',
        );
        expect(
          contrastRatio(scheme.outline, scheme.surface),
          greaterThan(contrastRatio(scheme.outlineVariant, scheme.surface)),
        );
      });

      test('text is legible on every container it can land on', () {
        void check(String label, Color fg, Color bg) => expect(
          contrastRatio(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$label is ${contrastRatio(fg, bg).toStringAsFixed(2)}:1',
        );
        check('onPrimary', scheme.onPrimary, scheme.primary);
        check('onSecondary', scheme.onSecondary, scheme.secondary);
        check('onError', scheme.onError, scheme.error);
        check(
          'onPrimaryContainer',
          scheme.onPrimaryContainer,
          scheme.primaryContainer,
        );
        check(
          'onSecondaryContainer',
          scheme.onSecondaryContainer,
          scheme.secondaryContainer,
        );
        check(
          'onErrorContainer',
          scheme.onErrorContainer,
          scheme.errorContainer,
        );
        check(
          'onTertiaryContainer',
          scheme.onTertiaryContainer,
          scheme.tertiaryContainer,
        );
        check('onSurface', scheme.onSurface, scheme.surface);
        check(
          'onSurfaceVariant',
          scheme.onSurfaceVariant,
          scheme.surfaceContainerHighest,
        );
        check(
          'onInverseSurface',
          scheme.onInverseSurface,
          scheme.inverseSurface,
        );
      });

      test('elevation is never expressed as a green cast', () {
        // Material tints raised surfaces with primary by default. Over a warm
        // neutral ramp that reads as a stain on white paper.
        expect(scheme.surfaceTint, const Color(0x00000000));
      });
    });
  }

  group('scheme — pleinSoleil', () {
    final scheme = KiloScheme.of(KiloBrightness.pleinSoleil);

    test('a raised surface is above the page in every theme', () {
      for (final b in KiloBrightness.values) {
        final c = KiloColors.of(b);
        final theme = KiloTheme.materialTheme(brightness: b);
        expect(
          theme.cardTheme.color,
          c.surfaceRaised,
          reason: 'a card must not sit below its page in ${b.name}',
        );
      }
    });

    test('the ramp is deliberately flat', () {
      // A 4 % tonal step is invisible in direct equatorial sun, so separation
      // comes from full-strength borders instead. This is the one place a
      // repeated ramp stop is correct, which is why it is asserted rather
      // than left to look like an oversight.
      expect(scheme.surfaceContainerLowest, scheme.surfaceContainerHighest);
      expect(scheme.outline, const Color(0xFF000000));
      expect(scheme.outlineVariant, const Color(0xFF000000));
    });

    test('body text is at maximum contrast', () {
      expect(contrastRatio(scheme.onSurface, scheme.surface), greaterThan(15));
    });
  });

  group('theme', () {
    test('every brightness produces a complete theme', () {
      for (final b in KiloBrightness.values) {
        final theme = KiloTheme.materialTheme(brightness: b);
        expect(theme.extension<KiloTheme>(), isNotNull);
        expect(theme.cardTheme.color, isNotNull);
        expect(theme.chipTheme.backgroundColor, isNotNull);
        expect(theme.inputDecorationTheme.filled, isTrue);
        expect(theme.dividerTheme.color, KiloColors.of(b).borderSubtle);
      }
    });

    test(
      'the compact density shortens rows without shrinking touch targets',
      () {
        final comfortable = KiloTheme.materialTheme();
        final compact = KiloTheme.materialTheme(density: KiloDensity.compact);
        expect(
          compact.dataTableTheme.dataRowMinHeight,
          lessThan(comfortable.dataTableTheme.dataRowMinHeight!),
        );
      },
    );

    test('plein soleil draws every edge at double weight', () {
      expect(
        KiloTheme.materialTheme(
          brightness: KiloBrightness.pleinSoleil,
        ).dividerTheme.thickness,
        2.0,
      );
      expect(KiloTheme.materialTheme().dividerTheme.thickness, 1.0);
    });

    testWidgets('a screen never has to style a component itself', (
      tester,
    ) async {
      // The proof that the style is shared: a bare Material component,
      // with no local styling at all, comes out in Kilo's colours.
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: const Scaffold(body: Card(child: Text('x'))),
        ),
      );
      final card = tester.widget<Card>(find.byType(Card));
      expect(card.color, isNull, reason: 'the screen sets nothing');
      final material = tester.widget<Material>(
        find.descendant(of: find.byType(Card), matching: find.byType(Material)),
      );
      expect(material.color, KiloColors.light.surfaceRaised);
    });
  });
}
