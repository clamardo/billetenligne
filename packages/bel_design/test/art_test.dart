import 'dart:io';
import 'dart:typed_data';

import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('artwork', () {
    test('every illustration and scene is drawn in the sentinel palette', () {
      const sentinels = {
        '#FF00E0',
        '#FF00E1',
        '#FF00E2',
        '#FF00E3',
        '#FF00E4',
        '#FF00E5',
        '#FF00E6',
        '#FF00E7',
      };
      for (final source in [
        ...KArt.values.map((a) => a.source),
        ...KSceneArt.values.map((s) => s.source),
      ]) {
        final used = RegExp(
          '#[0-9A-Fa-f]{3,8}',
        ).allMatches(source).map((m) => m[0]!.toUpperCase()).toSet();
        expect(
          used.difference(sentinels),
          isEmpty,
          reason:
              'artwork must not contain literal colours — see '
              'assets/README.md. A stray hex is invisible in review and '
              'unreadable in dark mode.',
        );
      }
    });

    test('the generated file matches the folder', () {
      // Guards the one failure this design can have: someone edits an SVG,
      // sees nothing change, and assumes the file is not wired up.
      final dir = Directory('assets/illustrations');
      if (!dir.existsSync()) return; // not run from the package root
      final onDisk = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.svg'))
          .length;
      expect(KArt.values.length, onDisk);
      expect(
        Directory('assets/scenes')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.svg'))
            .length,
        KSceneArt.values.length,
      );
    });

    test('every piece of artwork is well-formed and non-trivial', () {
      for (final source in [
        ...KArt.values.map((a) => a.source),
        ...KSceneArt.values.map((s) => s.source),
      ]) {
        expect(source, startsWith('<svg'));
        expect(source, endsWith('</svg>'));
        expect(source.length, greaterThan(200));
      }
    });

    test('the palette substitutes every sentinel for a real token', () {
      const art = KArt.noTrips;
      final painted = KArtPalette.from(KiloColors.dark).paint(art.source);
      expect(painted, isNot(contains('#FF00E')));
      expect(painted, contains(_hex(KiloColors.dark.contentPrimary)));
    });

    test('an operator accent overrides the brand without a second drawing', () {
      const hue = AccentHue.prune;
      final painted = KArtPalette.from(
        KiloColors.light,
        brand: hue.color,
      ).paint(KSceneArt.journey.source);
      expect(painted, contains(_hex(hue.color)));
      expect(painted, isNot(contains(_hex(KiloColors.light.brandPrimary))));
    });

    test('the same artwork paints differently in each theme', () {
      final light = KArtPalette.from(KiloColors.light).paint(KArt.route.source);
      final dark = KArtPalette.from(KiloColors.dark).paint(KArt.route.source);
      expect(light, isNot(dark));
    });

    testWidgets('an illustration is decorative unless it is given a label', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: const Scaffold(body: KIllustration(KArt.noTrips)),
        ),
      );
      // `SvgPicture` wraps itself in one too, so assert on the behaviour
      // rather than the count.
      expect(
        tester
            .widgetList<ExcludeSemantics>(find.byType(ExcludeSemantics))
            .any((e) => e.excluding),
        isTrue,
      );

      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: const Scaffold(
            body: KIllustration(KArt.noTrips, semanticLabel: 'Aucun départ'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Aucun départ'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a hero prefers the operator photograph when there is one', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: Scaffold(
            body: KScene(
              KSceneArt.journey,
              cover: MemoryImage(Uint8List.fromList(_pixel)),
            ),
          ),
        ),
      );
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('patterns', () {
    testWidgets('flat paints only its background', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: const Scaffold(
            body: KPattern(motif: KPatternMotif.flat, height: 60),
          ),
        ),
      );
      expect(find.byType(KPattern), findsOneWidget);
    });

    test('an unknown motif falls back rather than throwing', () {
      // Comes out of a database column. A storefront with a stale motif name
      // should still render a header, not a crash.
      expect(KPatternMotif.byName('sculpture'), KPatternMotif.flat);
      expect(KPatternMotif.byName(null), KPatternMotif.flat);
      expect(KPatternMotif.byName('vagues'), KPatternMotif.vagues);
    });
  });
}

String _hex(Color c) {
  String pair(double v) =>
      (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${pair(c.r)}${pair(c.g)}${pair(c.b)}';
}

/// A 1×1 transparent PNG.
const _pixel = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
