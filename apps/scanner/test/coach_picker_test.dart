import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_scanner/src/presentation/pages/coach_picker_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen between signing in and the door.
///
/// It is read once, in a yard, in the sun, by somebody holding a phone in one
/// hand — so what is tested here is what it *says*, not how it is built.
void main() {
  BoardingDepartureDto coach({
    String id = 'dep-1',
    String status = 'scheduled',
    String? stationName = 'Gare routière de Brazzaville',
  }) => BoardingDepartureDto(
    id: id,
    routeCode: 'BZV>PNR',
    originCity: 'Brazzaville',
    destinationCity: 'Pointe-Noire',
    departsAt: DateTime.utc(2026, 8, 15, 6),
    expected: 41,
    capacity: 49,
    status: status,
    stationName: stationName,
  );

  Widget wrap(Widget child) => MaterialApp(
    theme: KiloTheme.materialTheme(brightness: KiloBrightness.pleinSoleil),
    home: child,
  );

  testWidgets('names the road, the count and the yard', (tester) async {
    await tester.pumpWidget(
      wrap(
        CoachPickerPage(
          coaches: [coach()],
          onPick: (_) {},
          onRefresh: () async {},
        ),
      ),
    );

    expect(find.text('Brazzaville → Pointe-Noire'), findsOneWidget);
    expect(
      find.text('41 billets · 49 places · Gare routière de Brazzaville'),
      findsOneWidget,
    );
  });

  testWidgets('a tap picks that coach', (tester) async {
    String? picked;
    await tester.pumpWidget(
      wrap(
        CoachPickerPage(
          coaches: [
            coach(),
            coach(id: 'dep-2'),
          ],
          onPick: (c) => picked = c.id,
          onRefresh: () async {},
        ),
      ),
    );

    await tester.tap(find.text('Brazzaville → Pointe-Noire').last);
    expect(picked, 'dep-2');
  });

  testWidgets('a cancelled departure cannot be boarded', (tester) async {
    var picked = false;
    await tester.pumpWidget(
      wrap(
        CoachPickerPage(
          coaches: [coach(status: 'cancelled')],
          onPick: (_) => picked = true,
          onRefresh: () async {},
        ),
      ),
    );

    expect(find.text('Départ annulé'), findsOneWidget);
    await tester.tap(find.text('Brazzaville → Pointe-Noire'));
    expect(picked, isFalse);
  });

  testWidgets('while one is downloading, nothing else can be tapped', (
    tester,
  ) async {
    var picked = false;
    await tester.pumpWidget(
      wrap(
        CoachPickerPage(
          coaches: [
            coach(),
            coach(id: 'dep-2'),
          ],
          onPick: (_) => picked = true,
          onRefresh: () async {},
          pinning: 'dep-1',
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Brazzaville → Pointe-Noire').last);
    expect(picked, isFalse);
  });

  testWidgets('no coach today says why, and offers a retry', (tester) async {
    var refreshed = 0;
    await tester.pumpWidget(
      wrap(
        CoachPickerPage(
          coaches: const [],
          onPick: (_) {},
          onRefresh: () async => refreshed++,
        ),
      ),
    );

    expect(find.text("Aucun départ aujourd'hui."), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Actualiser'));
    await tester.pump();
    expect(refreshed, 1);
  });

  testWidgets('a refusal is a sentence, not a status code', (tester) async {
    await tester.pumpWidget(
      wrap(
        CoachPickerPage(
          coaches: const [],
          onPick: (_) {},
          onRefresh: () async {},
          failure: 'Pas de réseau. Rapprochez-vous du bureau et réessayez.',
        ),
      ),
    );

    expect(
      find.text('Pas de réseau. Rapprochez-vous du bureau et réessayez.'),
      findsOneWidget,
    );
  });
}
