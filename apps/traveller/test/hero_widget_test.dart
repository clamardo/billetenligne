import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  Widget host(Widget child, {KiloModeController? mode}) {
    final screen = Localized(
      catalog: catalog,
      initialLanguage: 'fr',
      child: MaterialApp(
        theme: KiloTheme.materialTheme(),
        darkTheme: KiloTheme.materialTheme(brightness: KiloBrightness.dark),
        themeMode: (mode?.mode ?? KiloMode.system).materialMode,
        home: child,
      ),
    );
    return mode == null ? screen : KiloModeScope(notifier: mode, child: screen);
  }

  const cities = [
    CityOption('BZV', 'Brazzaville'),
    CityOption('PNR', 'Pointe-Noire'),
  ];

  Widget search({VoidCallback? onOpenTickets}) => SearchScreen(
    cities: cities,
    onSearch: (_) {},
    onOpenTickets: onOpenTickets,
  );

  testWidgets('the home screen opens on the artwork, not on a line of text', (
    tester,
  ) async {
    await tester.pumpWidget(host(search()));
    await tester.pumpAndSettle();

    expect(find.byType(KScene), findsOneWidget);
    expect(tester.widget<KScene>(find.byType(KScene)).scene, KSceneArt.journey);
    // The headline moved onto the artwork; it must still be there.
    expect(find.text('Où allez-vous ?'), findsOneWidget);
  });

  testWidgets('the hero does not overflow on a short handset', (tester) async {
    // The hero is a fixed height with a headline and a tagline on it. A flex
    // that overruns it by six pixels is a striped bar across the top of the
    // app, and it only shows up at a particular size.
    tester.view
      ..physicalSize = const Size(320, 560)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(search()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the theme toggle is on the home screen and changes the app', (
    tester,
  ) async {
    final mode = KiloModeController(initial: KiloMode.light);
    await tester.pumpWidget(host(search(), mode: mode));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.dark_mode_outlined));
    await tester.pumpAndSettle();
    expect(mode.mode, KiloMode.dark);
  });

  // A phone taller than the form left a band of flat cream below the panel,
  // and the screen read as a card dropped onto nothing. The ground is painted
  // under the whole page, and the space carries the three things the form
  // cannot say.
  testWidgets('the page has a ground under it, not just under the hero', (
    tester,
  ) async {
    await tester.pumpWidget(host(search()));
    await tester.pumpAndSettle();

    // The hero's own art, plus the page's ground beneath it.
    expect(find.byType(KPattern), findsWidgets);
    final page = tester.widget<KPattern>(find.byType(KPattern).first);
    expect(page.motif, KPatternMotif.diagonale);
  });

  testWidgets('the space below the form says what the form cannot', (
    tester,
  ) async {
    await tester.pumpWidget(host(search()));
    await tester.pumpAndSettle();

    // Below the fold on a test-sized window, which is the point: it fills the
    // space a tall handset leaves rather than competing with the form.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('Choisissez votre place sur le plan du car.'), findsOne);
    expect(
      find.text("Payez par Mobile Money. Pas d'espèces à la porte."),
      findsOne,
    );
  });

  testWidgets('with no controller anywhere the toggle simply is not there', (
    tester,
  ) async {
    await tester.pumpWidget(host(search()));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.dark_mode_outlined), findsNothing);
    expect(find.byIcon(Icons.light_mode_outlined), findsNothing);
  });
}
