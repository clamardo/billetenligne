import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/application/payment_flow.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/payment_checkout_screen.dart';
import 'package:bel_traveller/src/presentation/screens/payment_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'booking_flow_test.dart' show ScriptedGatewayFactory, cardOption;
import 'catalog_fixture.dart';

/// The card rail's two screens.
///
/// Kept apart from `funnel_widget_test` because nothing about this path is the
/// funnel: it leaves the app entirely, and what is worth asserting is what the
/// traveller is told before and after they go.
void main() {
  late TranslationCatalog catalog;

  setUpAll(() async {
    catalog = await loadTestCatalog();
  });

  Future<void> pump(WidgetTester tester, Widget screen) => tester.pumpWidget(
    Localized(
      catalog: catalog,
      child: MaterialApp(theme: KiloTheme.materialTheme(), home: screen),
    ),
  );

  final intent = PaymentIntentDto(
    id: 'pi-1',
    state: 'pending',
    railId: 'cg.card',
    amount: const Money.xaf(12300),
    createdAt: DateTime.utc(2026, 8, 9, 6),
    redirectUrl: 'https://checkout.invalid/pay/pi-1',
  );

  group('the checkout screen', () {
    testWidgets('hands over the page and says whose it is', (tester) async {
      final opened = <String>[];

      await pump(
        tester,
        PaymentCheckoutScreen(
          step: AwaitingCheckout(intent: intent, option: cardOption),
          onOpen: opened.add,
          onCancel: () {},
        ),
      );

      // The reassurance that makes somebody willing to type a card number:
      // it is not typed here.
      expect(
        find.textContaining('jamais dans cette application'),
        findsOneWidget,
      );
      // The rail names itself in the bar rather than the screen calling
      // everything a card.
      expect(find.text('Carte bancaire'), findsWidgets);

      await tester.tap(find.text('Ouvrir la page de paiement'));
      expect(opened, ['https://checkout.invalid/pay/pi-1']);
    });

    testWidgets('can be opened again without a second payment', (tester) async {
      final opened = <String>[];

      await pump(
        tester,
        PaymentCheckoutScreen(
          step: AwaitingCheckout(intent: intent, option: cardOption),
          onOpen: opened.add,
          onCancel: () {},
        ),
      );

      await tester.tap(find.text('Ouvrir la page de paiement'));
      await tester.tap(find.text('Ouvrir la page de paiement'));

      // Same page twice. The intent is the transaction, and reopening its
      // page is not a second one — the caption says so, and this is it.
      expect(opened, hasLength(2));
      expect(opened.toSet(), hasLength(1));
    });

    testWidgets('waits rather than opening a blank browser', (tester) async {
      final pending = PaymentIntentDto(
        id: 'pi-2',
        state: 'pending',
        railId: 'cg.card',
        amount: const Money.xaf(12300),
        createdAt: DateTime.utc(2026, 8, 9, 6),
      );

      await pump(
        tester,
        PaymentCheckoutScreen(
          step: AwaitingCheckout(intent: pending, option: cardOption),
          onOpen: (_) => fail('there is no page to open yet'),
          onCancel: () {},
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Ouvrir la page de paiement'), findsNothing);
    });

    testWidgets('leaving is not cancelling, and says so', (tester) async {
      await pump(
        tester,
        PaymentCheckoutScreen(
          step: AwaitingCheckout(intent: intent, option: cardOption),
          onOpen: (_) {},
          onCancel: () {},
        ),
      );

      // Somebody who has already typed a card number must never be told the
      // payment is cancelled: it may well have gone through.
      expect(find.textContaining('le paiement continue'), findsOneWidget);
    });

    testWidgets('with no browser wired the link is still reachable', (
      tester,
    ) async {
      await pump(
        tester,
        PaymentCheckoutScreen(
          step: AwaitingCheckout(intent: intent, option: cardOption),
          onOpen: null,
          onCancel: () {},
        ),
      );

      expect(find.text('https://checkout.invalid/pay/pi-1'), findsOneWidget);
    });
  });

  group('the method screen', () {
    Future<PaymentFlow> reachMethod(WidgetTester tester) async {
      final gateway = ScriptedGatewayFactory()
        ..options = [...ScriptedGatewayFactory.walletOptions, cardOption];
      final flow = PaymentFlow(gateway: gateway);
      await flow.start('bk-1');
      addTearDown(flow.dispose);
      return flow;
    }

    testWidgets('a wallet asks for a number to debit', (tester) async {
      final flow = await reachMethod(tester);

      await pump(
        tester,
        PaymentMethodScreen(
          step: flow.step as ChoosingMethod,
          flow: flow,
          onBack: () {},
        ),
      );

      expect(find.text('Numéro à débiter'), findsOneWidget);
    });

    testWidgets('a card asks for nothing', (tester) async {
      final flow = await reachMethod(tester);
      flow.chooseRail(cardOption);

      await pump(
        tester,
        PaymentMethodScreen(
          step: flow.step as ChoosingMethod,
          flow: flow,
          onBack: () {},
        ),
      );

      // The field is gone rather than disabled: a greyed-out box still reads
      // as something the traveller failed to fill in.
      expect(find.text('Numéro à débiter'), findsNothing);
      // Named, not assumed: the sentence carries the rail's own label, which
      // is what lets Orange Money use this screen without reading as a bank.
      expect(
        find.textContaining('la page sécurisée de Carte bancaire'),
        findsOneWidget,
      );
    });

    testWidgets('a card tile shows no collection number', (tester) async {
      final flow = await reachMethod(tester);

      await pump(
        tester,
        PaymentMethodScreen(
          step: flow.step as ChoosingMethod,
          flow: flow,
          onBack: () {},
        ),
      );

      // A wallet tile names who is being paid. A card has nobody to name —
      // and an empty "· " beside a rail is exactly what a scam looks like.
      expect(find.textContaining('Ocean du Nord ·'), findsWidgets);
      expect(find.textContaining('Visa ou Mastercard'), findsOneWidget);
    });
  });
}
