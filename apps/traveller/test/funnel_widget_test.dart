import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_traveller/src/application/booking_flow.dart';
import 'package:bel_traveller/src/application/payment_flow.dart';
import 'package:bel_traveller/src/application/sign_in_flow.dart';
import 'package:bel_traveller/src/application/tickets_flow.dart';
import 'package:bel_traveller/src/infrastructure/demo_identity_gateway.dart';
import 'package:bel_traveller/src/infrastructure/demo_travel_gateway.dart';
import 'package:bel_traveller/src/presentation/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'catalog_fixture.dart';

/// The funnel, end to end, through the widgets a traveller actually taps.
///
/// Runs against the demo gateway rather than a mock, on purpose: the demo
/// gateway holds seats for real, so "the seat I just took is now marked taken"
/// is exercised here rather than asserted about a fake that always says yes.
void main() {
  late TranslationCatalog catalog;
  late DemoIdentityGateway identity;

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
    // Signed in by default, because most of these tests are about screens
    // that live *after* the gate. The gate itself is exercised by the group
    // that passes false.
    bool signedIn = true,
    List<String> channels = const ['email'],
  }) async {
    final gateway = DemoTravelGateway(now: DateTime.utc(2026, 8, 9, 6))
      // Instant, so the tests are about behaviour rather than about waiting.
      ..latency = Duration.zero;

    identity =
        DemoIdentityGateway(
            now: () => DateTime.utc(2026, 8, 9, 6),
            signedInAs: signedIn
                ? const AccountDto(
                    id: 'u-test',
                    language: 'fr',
                    email: 'a@b.cg',
                  )
                : null,
          )
          ..latency = Duration.zero
          ..channels = channels;

    final flow = BookingFlow(
      gateway: gateway,
      isSignedIn: () => identity.isSignedIn,
    );

    await tester.pumpWidget(
      TravellerApp(
        catalog: catalog,
        flow: flow,
        signIn: SignInFlow(gateway: identity),
        payment: PaymentFlow(gateway: gateway),
        tickets: TicketsFlow(gateway: gateway),
        language: language,
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
      // 08-disruption.md §6: the operator's on-time record, on the row where
      // the choice is actually made. Worded by the catalog, never by the
      // server, and drawn only where there is a figure to draw.
      expect(find.textContaining("à l'heure"), findsWidgets);
    });

    testWidgets('a coach that takes the long road says which way', (
      tester,
    ) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      // Named, not coded: the client already holds the city catalogue for its
      // own search form, so a server sending names would be sending prose in
      // whichever language the row was written in.
      expect(find.textContaining('via Dolisie'), findsWidgets);
      // And it is a road, not an offer — buying a seat to Dolisie on this
      // coach is not built, and the wording must not suggest it is.
      expect(find.textContaining('arrêt'), findsNothing);
    });

    testWidgets('the yard is on the row when the yards differ', (tester) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      // Two of the demo coaches leave from the other side of Brazzaville.
      // That difference is a journey decision, so it is on the row rather
      // than three taps away on a confirmation screen.
      expect(find.textContaining('Gare de Mikalou'), findsWidgets);
      expect(find.textContaining('Gare de Kinsoundi'), findsWidgets);
    });
  });

  group('more results', () {
    testWidgets('a partial list never states a count it will outgrow', (
      tester,
    ) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      // Nine coaches, four to a page. "9 départs" here would be a number that
      // was wrong at the moment somebody read it.
      expect(find.textContaining('et plus'), findsOneWidget);
    });

    testWidgets('scrolling reaches coaches the first page did not hold', (
      tester,
    ) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      expect(
        tester.widgetList(find.byType(KTripCard)),
        hasLength(lessThanOrEqualTo(DemoTravelGateway.demoPageSize)),
      );

      for (var i = 0; i < 4; i++) {
        await tester.drag(find.byType(ListView).last, const Offset(0, -1200));
        await tester.pumpAndSettle();
      }

      // Nobody pressed anything: reaching the foot of the list is the whole
      // gesture, which is what it has to be on a connection where the second
      // page takes a moment.
      expect(find.textContaining('et plus'), findsNothing);
      expect(find.textContaining('9 départs'), findsOneWidget);
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

    testWidgets('signing in is asked for at the seat, not at launch', (
      tester,
    ) async {
      final flow = await pumpApp(tester, signedIn: false);

      // Everything up to here is open, and that is the point: forcing sign-up
      // before somebody has seen a price is the largest avoidable drop-off in
      // this funnel (ADR-0013).
      await searchBzvToPnr(tester);
      expect(find.textContaining('Ocean du Nord'), findsWidgets);

      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();

      // The gate opens here, and only here.
      await tester.tap(find.textContaining('Continuer'));
      await tester.pumpAndSettle();

      expect(flow.step, isA<NeedsIdentity>());
      expect(find.text('Presque à vous'), findsOneWidget);
      // No password, and it says so — somebody expecting to have to remember
      // one and unable to is somebody who abandons the purchase.
      expect(find.textContaining('Pas de mot de passe'), findsOneWidget);
    });

    testWidgets('SMS is named as coming, not silently missing', (tester) async {
      await pumpApp(tester, signedIn: false);
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Continuer'));
      await tester.pumpAndSettle();

      // Second, not absent (ADR-0024) — and the sentence is here because the
      // server did not announce the channel, not because it is hardcoded.
      expect(find.textContaining('SMS arrive bientôt'), findsOneWidget);
      expect(find.text('Par SMS'), findsNothing);
    });

    testWidgets('the day a sender is provisioned, the option appears', (
      tester,
    ) async {
      await pumpApp(
        tester,
        signedIn: false,
        channels: const ['email', 'phone'],
      );
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Continuer'));
      await tester.pumpAndSettle();

      // No release, no rebuild: the server said so (ADR-0006).
      expect(find.text('Par SMS'), findsOneWidget);
      expect(find.textContaining('SMS arrive bientôt'), findsNothing);

      await tester.tap(find.text('Par SMS'));
      await tester.pumpAndSettle();

      expect(find.text('Recevoir un code par SMS'), findsOneWidget);
    });

    testWidgets('a code signs in and resumes the hold that was interrupted', (
      tester,
    ) async {
      final flow = await pumpApp(tester, signedIn: false);
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Continuer'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'aline@example.cg');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recevoir un code'));
      await tester.pumpAndSettle();

      expect(find.text('Entrez le code'), findsOneWidget);
      expect(find.textContaining('a***e@example.cg'), findsOneWidget);

      // A wrong code first: it must not throw them out of the screen, because
      // the real code is sitting in their inbox.
      await tester.enterText(find.byType(TextField).first, '000000');
      await tester.pumpAndSettle();
      expect(find.text('Entrez le code'), findsOneWidget);
      expect(find.textContaining('Code incorrect'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '424242');
      await settleHoldScreen(tester);
      await settleHoldScreen(tester);

      // Resumed, not restarted: the seat they chose before being interrupted
      // is the seat they now hold.
      expect(flow.step, isA<HoldReady>());
      expect((flow.step as HoldReady).hold.seatLabels, ['1A']);
    });

    testWidgets('backing out of signing in keeps the seat selected', (
      tester,
    ) async {
      final flow = await pumpApp(tester, signedIn: false);
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Continuer'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // Making somebody choose their seat again because they changed their
      // mind about signing in is a good way to lose them.
      expect(flow.step, isA<ChoosingSeats>());
      expect((flow.step as ChoosingSeats).selected, {'1A'});
      expect(find.text('1 place choisie'), findsOneWidget);
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

    testWidgets('a held seat becomes a payment code to take to an agency', (
      tester,
    ) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);
      await tester.tap(find.textContaining('Ocean du Nord').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('1A'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Continuer'));
      await settleHoldScreen(tester);

      // The pay button collects names rather than opening a screen that
      // apologises: cash at an agency IS the pilot's payment story.
      await tester.tap(find.textContaining('Payer'));
      await tester.pumpAndSettle();
      expect(find.text('Qui voyage ?'), findsOneWidget);

      // Nameless passengers cannot be reserved — a conductor reads that name
      // aloud against a face.
      expect(find.text("Indiquez le nom de chaque passager"), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Aline M.');
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Réserver'));
      await tester.pumpAndSettle();

      expect(find.text('Réservation confirmée'), findsOneWidget);
      // Spaced, because a five-character code read aloud is read in pieces.
      expect(find.text('K 4 M 2 Q'), findsOneWidget);
      // Which agency, and by when. Scrolled to, because the deadline sits
      // below the fold on a test-sized screen and `findsOneWidget` only sees
      // what a ListView has actually built.
      expect(find.textContaining('agence'), findsOneWidget);
      // Dragged rather than `scrollUntilVisible`: that helper requires
      // exactly one Scrollable and this screen's Scaffold has more than one.
      await tester.drag(find.byType(ListView).last, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.textContaining('À payer avant'), findsOneWidget);

      // No QR anywhere: the money has not moved, and a screen that looked
      // like a ticket before payment is the most confusing thing this flow
      // could do.
      expect(find.textContaining('QR'), findsOneWidget);
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

  group('tickets', () {
    testWidgets('a bought ticket is two taps from the search screen', (
      tester,
    ) async {
      await pumpApp(tester);

      // The icon on the search screen, because a returning traveller opens
      // this app for exactly two reasons and showing a ticket is one of them.
      await tester.tap(find.byIcon(Icons.confirmation_number_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Mes billets'), findsWidgets);
      expect(find.text('Voyages passés'), findsOneWidget);

      await tester.tap(find.text('Pointe-Noire → Brazzaville'));
      await tester.pumpAndSettle();

      // The QR, and the six digits under it that a screenshot cannot fake.
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('Code de contrôle'), findsOneWidget);
    });

    testWidgets('closing a ticket returns to where the traveller was', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.confirmation_number_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pointe-Noire → Brazzaville'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Mes billets'), findsWidgets);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      // Back at the search screen, not at some top of the app it invented.
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

  group('a coach that is full', () {
    testWidgets('a sold-out row is shown, and offers to tell them', (
      tester,
    ) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      // Dimmed, not hidden: seeing that the coach is full is how somebody
      // learns to book earlier, and hiding it makes the service look empty.
      expect(find.text('Complet'), findsOneWidget);
      expect(find.text('Prevenez-moi'), findsOneWidget);
    });

    testWidgets('the offer never promises a seat', (tester) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      await tester.tap(find.text('Prevenez-moi'));
      await tester.pumpAndSettle();

      expect(find.text('Car complet'), findsOneWidget);
      // The sentence the whole screen exists for. "We'll let you know" reads
      // as "you have a seat", and that reading ends with somebody at a
      // station at 05:30 for a coach that filled overnight.
      expect(find.textContaining("Aucune place n'est gardee"), findsOneWidget);
    });

    testWidgets('asking turns the screen into a confirmation', (tester) async {
      await pumpApp(tester);
      await searchBzvToPnr(tester);

      await tester.tap(find.text('Prevenez-moi'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(KButton, 'Prevenez-moi'));
      await tester.pumpAndSettle();

      expect(find.text('Vous serez prevenu'), findsOneWidget);
      // One message, said out loud. An alert that fires twice is an alert
      // people mute.
      expect(find.textContaining('un seul message'), findsOneWidget);
      expect(find.text('Ne plus me prevenir'), findsOneWidget);
    });

    testWidgets('an anonymous traveller is asked who they are', (tester) async {
      await pumpApp(tester, signedIn: false);
      await searchBzvToPnr(tester);

      await tester.tap(find.text('Prevenez-moi'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(KButton, 'Prevenez-moi'));
      await tester.pumpAndSettle();

      // An alert is a promise to send somebody a message. Anonymous, there is
      // nobody to send it to.
      expect(find.text('Car complet'), findsNothing);
      expect(find.byType(TextField), findsWidgets);
    });
  });

  group('going again', () {
    testWidgets('a past trip offers the return, named by city', (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.confirmation_number_outlined));
      await tester.pumpAndSettle();

      // The booking carries `PNR`, because that is what the route is keyed
      // on. A screen that printed it would be asking somebody to read a
      // database.
      expect(find.text('Retour vers Pointe-Noire'), findsOneWidget);
      expect(find.text('Refaire ce trajet'), findsOneWidget);
    });

    testWidgets('the return lands on the results for the other direction', (
      tester,
    ) async {
      final flow = await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.confirmation_number_outlined));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retour vers Pointe-Noire'));
      await tester.pumpAndSettle();

      // The past trip was PNR → BZV, so the return is BZV → PNR — and it is
      // the results, not a form to fill in again.
      expect(flow.step, isA<ResultsReady>());
      expect(flow.lastQuery!.originCity, 'BZV');
      expect(flow.lastQuery!.destinationCity, 'PNR');
    });

    testWidgets('backing out lands on a form that already knows the road', (
      tester,
    ) async {
      final flow = await pumpApp(tester);
      await tester.tap(find.byIcon(Icons.confirmation_number_outlined));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Refaire ce trajet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refaire ce trajet'));
      await tester.pumpAndSettle();
      expect(flow.step, isA<ResultsReady>());

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      // The date is the one thing left to change, which is the whole point of
      // going through the results first.
      expect(find.text('Où allez-vous ?'), findsOneWidget);
      expect(find.text('Brazzaville'), findsWidgets);
    });
  });
}
