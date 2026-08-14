import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// The screen a release build shows when it was assembled without a server.
///
/// It exists so that an APK built with no `BEL_API_URL` cannot be mistaken for
/// the product: without it the demo gateways answer, and somebody handed the
/// file by an agency searches, chooses a seat and is given a payment code for
/// a coach no operator has heard of.
///
/// The condition itself — `kReleaseMode` — cannot be reached from a test, so
/// what is checked here is the half that can be: that the screen says what it
/// is, in the language of the market, in both.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  testWidgets('says the build has no server, in French', (tester) async {
    await tester.pumpWidget(
      UnconfiguredBuild(catalog: catalog, language: 'fr'),
    );

    expect(find.textContaining('aucun serveur'), findsOneWidget);
    expect(find.textContaining('Désinstallez'), findsOneWidget);
  });

  testWidgets('and in English', (tester) async {
    await tester.pumpWidget(
      UnconfiguredBuild(catalog: catalog, language: 'en'),
    );

    expect(find.textContaining('not connected to a server'), findsOneWidget);
  });

  testWidgets('offers nothing to do', (tester) async {
    await tester.pumpWidget(
      UnconfiguredBuild(catalog: catalog, language: 'fr'),
    );

    // No button, no field, no route out. A screen that looked like the app
    // would invite somebody to try, and there is nothing here that works.
    expect(find.byType(TextField), findsNothing);
    expect(find.byWidgetPredicate((w) => w is ButtonStyleButton), findsNothing);
  });
}
