import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KiloMode', () {
    test('an unknown stored value follows the platform', () {
      // The value comes off disk, written by a version of the app that may
      // not be this one. Falling back is the only behaviour that lets a theme
      // be renamed without stranding everyone who had chosen it.
      expect(KiloMode.byName('midnight'), KiloMode.system);
      expect(KiloMode.byName(null), KiloMode.system);
      expect(KiloMode.byName('dark'), KiloMode.dark);
    });

    test('each mode maps to the Material one', () {
      expect(KiloMode.system.materialMode, ThemeMode.system);
      expect(KiloMode.light.materialMode, ThemeMode.light);
      expect(KiloMode.dark.materialMode, ThemeMode.dark);
    });
  });

  group('KiloModeController', () {
    test('a change notifies and is handed to the persister exactly once', () {
      final written = <KiloMode>[];
      var notified = 0;
      final controller = KiloModeController(onChanged: written.add)
        ..addListener(() => notified++);

      controller.mode = KiloMode.dark;
      expect(written, [KiloMode.dark]);
      expect(notified, 1);
    });

    test('setting the mode it already holds writes nothing', () {
      // Otherwise every rebuild that re-asserts the current value costs a
      // disk write and a full-tree rebuild.
      final written = <KiloMode>[];
      final controller = KiloModeController(
        initial: KiloMode.dark,
        onChanged: written.add,
      );
      controller.mode = KiloMode.dark;
      expect(written, isEmpty);
    });

    testWidgets('the toggle chooses the opposite of what is on screen', (
      tester,
    ) async {
      // Including from `system`, which is the case that matters: somebody on
      // a dark handset who taps the toggle means "make it light", and a
      // controller that merely advances an enum would give them dark again.
      late BuildContext ctx;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.dark),
          child: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final controller = KiloModeController();
      controller.toggle(ctx);
      expect(controller.mode, KiloMode.light);
      controller.toggle(ctx);
      expect(controller.mode, KiloMode.dark);
    });
  });

  group('KModeToggle', () {
    testWidgets('draws nothing when no app wired a controller', (tester) async {
      // Screens are mounted on their own in tests all the time. A control the
      // app cannot honour is worse than no control.
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: const Scaffold(body: KModeToggle()),
        ),
      );
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('finds the controller through the scope and flips the app', (
      tester,
    ) async {
      final controller = KiloModeController(initial: KiloMode.light);
      await tester.pumpWidget(
        KiloModeScope(
          notifier: controller,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => MaterialApp(
              theme: KiloTheme.materialTheme(),
              darkTheme: KiloTheme.materialTheme(
                brightness: KiloBrightness.dark,
              ),
              themeMode: controller.mode.materialMode,
              home: const Scaffold(body: KModeToggle()),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(controller.mode, KiloMode.dark);
      expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
      final scaffold = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(Scaffold),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(scaffold.color, KiloColors.dark.surfaceBase);
    });

    testWidgets('the three-way choice can get back to following the platform', (
      tester,
    ) async {
      final controller = KiloModeController(initial: KiloMode.dark);
      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: Scaffold(body: KModeChoice(controller: controller)),
        ),
      );
      await tester.tap(find.text('Système'));
      await tester.pumpAndSettle();
      expect(controller.mode, KiloMode.system);
    });
  });
}
