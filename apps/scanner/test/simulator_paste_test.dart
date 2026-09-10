import 'package:bel_localization/bel_localization.dart';
import 'package:bel_scanner/src/presentation/widgets/ticket_simulator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// The debug simulator, on a coach that is real.
///
/// The canned list is empty against a live manifest and always will be — a
/// canned scan needs a signed payload and a live secret, which only the demo
/// departure holds. That left the one case worth rehearsing most out of
/// reach: a genuine ticket, bought on the handset beside this one, presented
/// to a manifest pinned from the server. The paste field is that case, and
/// these tests are what keep it from being quietly deleted as unused.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  Future<List<(String, String?)>> pump(WidgetTester tester) async {
    final seen = <(String, String?)>[];
    await tester.pumpWidget(
      scannerHarness(
        catalog,
        Scaffold(
          body: TicketSimulator(
            scans: const [],
            onScan: (raw, code) => seen.add((raw, code)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return seen;
  }

  testWidgets('it renders with nothing canned in it', (tester) async {
    await pump(tester);

    // Sentences, not dotted keys: this sheet is the one screen in the app a
    // developer meets before anybody else does, and a raw key here has
    // shipped before.
    expect(find.text("Coller le contenu d'un QR"), findsOneWidget);
    expect(find.text('Le lire'), findsOneWidget);
    expect(find.textContaining('scanner.simulator'), findsNothing);
  });

  testWidgets('a pasted payload goes to the reader unchanged', (tester) async {
    final seen = await pump(tester);

    const payload = '1|BEL|QAF6YV|3B|dep-1|1789016400|BZV-PNR|DEMO-ALZ|A|1.sig';
    await tester.enterText(find.byType(TextField), '  $payload  ');
    await tester.tap(find.text('Le lire'));
    await tester.pump();

    // Trimmed — a paste off a terminal carries a newline — and handed over
    // with no code beside it, because a live QR already contains its own.
    expect(seen, [(payload, null)]);
  });

  testWidgets('an empty field is not a scan', (tester) async {
    final seen = await pump(tester);

    await tester.tap(find.text('Le lire'));
    await tester.pump();

    expect(seen, isEmpty);
  });
}
