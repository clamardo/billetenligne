import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/application/booking_flow.dart';
import 'package:bel_traveller/src/infrastructure/demo_travel_gateway.dart';
import 'package:bel_traveller/src/presentation/app.dart';
import 'package:bel_traveller/src/presentation/screens/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// The funnel, end to end, through the widgets a traveller actually taps.
///
/// Runs against the demo gateway rather than a mock, on purpose: the demo
/// gateway holds seats for real, so "the seat I just took is now marked taken"
/// is exercised here rather than asserted about a fake that always says yes.
void main() {
  late TranslationCatalog catalog;

  setUpAll(() async {
    catalog = await loadTestCatalog();
  });

  /// Two traps in this file, both worth stating because both cost an hour.
  ///
  /// **Never `await` gateway work outside a pump.** A widget test runs in a
  /// fake-async zone where the clock only advances while pumping, so
  /// `await flow.holdSelection()` on its own hangs forever waiting on a
  /// `Future.delayed` that will never fire. Drive the funnel through taps.
  ///
  /// **Never `pumpAndSettle` on the hold screen.** It settles only when
  /// nothing is scheduled, and the countdown schedules a frame every second
  /// for as long as it lives. Explicit pumps instead — which is also closer to
  /// what the screen actually does.
  Future<void> settleHoldScreen(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<BookingFlow> pumpApp(
    WidgetTester tester, {
    String language = 'fr',
  }) async {
    final gateway = DemoTravelGateway(now: DateTime.utc(2026, 8, 9, 6))
      // Instant, so the tests are about behaviour rather than about waiting.
      ..latency = Duration.zero;
    final flow = BookingFlow(gateway: gateway);

    await tester.pumpWidget(
      TravellerApp(
        catalog: catalog,
        flow: flow,
        language: language,
        cities: const [
          CityOption('BZV', 'Brazzaville'),
          CityOption('PNR', 'Pointe-Noire'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return flow;
  }

  Future<void> searchBzvToPnr(WidgetTester tester) async {
    // The origin defaults to the first city; choose the destination. Found by
    // type rather than by its placeholder, so the test does not break every
    // time somebody improves the copy.
    await tester.tap(find.byType(DropdownButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pointe-Noire').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rechercher un départ'));
    await tester.pumpAndSettle();
  }

  group('search', () {
    testWidgets('opens on the search screen, in French', (tester) async {
      await pumpApp(tester);

      expect(find.text('Où allez-vous ?'), findsOneWidget);
    });

    testWidgets('the search button explains why it is disabled', (
      tester,
    ) async {
      await pumpApp(tester);

      // No destination chosen yet. A greyed button with no explanation is the
      // most common way an app strands somebody.
      expect(find.text('Choisissez un départ et une arrivée'), findsOneWidget);
    });

    testWidgets('finds departures and lists them', (tester) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      expect(find.textContaining('Ocean du Nord'), findsWidgets);
      expect(find.byType(ListView), findsWidgets);
    });
  });

  group('the whole funnel', () {
    testWidgets('search, pick a coach, pick a seat, hold it', (tester) async {
      final flow = await pumpApp(tester);
      await searchBzvToPnr(tester);

      // Open the first coach.
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      expect(find.text('Choisissez votre place'), findsOneWidget);

      // Nothing chosen yet: the button says what to do rather than nothing.
      expect(find.text('Choisissez au moins une place'), findsOneWidget);

      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      expect(find.text('1 place choisie'), findsOneWidget);

      // The continue button now carries the total.
      final continueButton = find.textContaining('Continuer');
      expect(continueButton, findsOneWidget);
      await tester.tap(continueButton);
      await settleHoldScreen(tester);

      expect(flow.step, isA<HoldReady>());
      expect(find.text('Votre place est réservée'), findsOneWidget);
      // The countdown is the point of this screen.
      expect(find.textContaining('Place réservée'), findsOneWidget);
    });

    testWidgets('a seat somebody else has cannot be chosen', (tester) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      // The second coach in the demo timetable already has its first six
      // seats sold, which is what makes this assertion about inventory rather
      // than about a mock agreeing with whatever it is asked.
      await tester.tap(find.textContaining('Trans Bony Voyages').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();

      expect(find.text('1 place choisie'), findsNothing);

      // And a free one still works, so the map is not simply inert.
      await tester.tap(find.text('3A'));
      await tester.pumpAndSettle();
      expect(find.text('1 place choisie'), findsOneWidget);
    });

    testWidgets('the seat cap is stated, not silently enforced', (
      tester,
    ) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();

      for (final label in ['1A', '1B', '1C', '1D', '2A', '2B']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(find.text('6 places choisies'), findsOneWidget);

      await tester.tap(find.text('2C'));
      await tester.pumpAndSettle();

      // A control that just stops responding reads as a broken app.
      expect(find.textContaining('6 places au maximum'), findsOneWidget);
      expect(find.text('6 places choisies'), findsOneWidget);
    });

    testWidgets('releasing puts the seat back on sale', (tester) async {
      final flow = await pumpApp(tester);
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Continuer'));
      await settleHoldScreen(tester);

      // Below the fold on a 800×600 test viewport, as it is on a small
      // handset — the cancel action sits under the breakdown on purpose.
      await tester.ensureVisible(find.text('Annuler la réservation'));
      await tester.pump();
      await tester.tap(find.text('Annuler la réservation'));
      await tester.pumpAndSettle();

      expect(flow.step, isA<Idle>());
      expect(find.text('Où allez-vous ?'), findsOneWidget);
    });
  });

  group('language', () {
    testWidgets('renders in English when the device asks for it', (
      tester,
    ) async {
      await pumpApp(tester, language: 'en');

      expect(find.text('Where are you going?'), findsOneWidget);
      expect(find.text('Find a departure'), findsOneWidget);
    });

    testWidgets('an unsupported language falls back to French, not English', (
      tester,
    ) async {
      await pumpApp(tester, language: 'pt');

      // French is the source and the fallback (ADR-0008). Every traveller in
      // this market reads it; far fewer read English.
      expect(find.text('Où allez-vous ?'), findsOneWidget);
    });
  });
}
