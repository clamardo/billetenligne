import 'package:bel_design/bel_design.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/search_screen.dart';
import 'package:bel_traveller/src/presentation/screens/tickets_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog_fixture.dart';
import 'render_harness.dart';

/// Renders whole screens to `build/design/` so the design can be looked at.
/// Asserts nothing; see the note in `render_harness.dart`.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  const cities = [
    CityOption('BZV', 'Brazzaville'),
    CityOption('PNR', 'Pointe-Noire'),
    CityOption('DOL', 'Dolisie'),
  ];

  testWidgets('search on the narrowest handset', (tester) async {
    await shoot(
      tester,
      'traveller-search-narrow',
      Localized(
        catalog: catalog,
        initialLanguage: 'fr',
        child: SearchScreen(
          cities: cities,
          onSearch: (_) {},
          onOpenTickets: () {},
        ),
      ),
      size: const Size(320, 560),
    );
  });

  for (final b in [KiloBrightness.light, KiloBrightness.dark]) {
    testWidgets('search ${b.name}', (tester) async {
      await shoot(
        tester,
        'traveller-search-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: SearchScreen(
            cities: cities,
            onSearch: (_) {},
            onOpenTickets: () {},
          ),
        ),
        size: const Size(400, 860),
        brightness: b,
      );
    });

    testWidgets('empty tickets ${b.name}', (tester) async {
      await shoot(
        tester,
        'traveller-tickets-empty-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: TicketsScreen(
            upcoming: const [],
            past: const [],
            onBack: () {},
            onOpen: (_) {},
            onRefresh: () async {},
            onSearch: () {},
            onChoices: (_) {},
            onCancel: (_) {},
            onChange: (_) {},
          ),
        ),
        size: const Size(400, 860),
        brightness: b,
      );
    });
  }
}
