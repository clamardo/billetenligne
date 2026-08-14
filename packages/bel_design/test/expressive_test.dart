import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child, {bool noAnimations = false}) => MaterialApp(
    theme: KiloTheme.materialTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: noAnimations),
      child: Scaffold(body: child),
    ),
  );

  group('KTicketHeader', () {
    testWidgets('says the journey and who is running it', (tester) async {
      await tester.pumpWidget(
        host(
          const KTicketHeader(
            origin: 'Brazzaville',
            destination: 'Pointe-Noire',
            subtitle: 'sam. 15 août · 06 h 00',
            footnote: 'Ocean du Nord',
          ),
        ),
      );
      expect(find.text('Brazzaville → Pointe-Noire'), findsOneWidget);
      expect(find.text('sam. 15 août · 06 h 00'), findsOneWidget);
      expect(find.text('Ocean du Nord'), findsOneWidget);
    });

    testWidgets('takes the operator hue, and looks deliberate without one', (
      tester,
    ) async {
      // Most operators on day one have never opened the vitrine. The default
      // has to be a decision rather than an absence.
      await tester.pumpWidget(
        host(const KTicketHeader(origin: 'A', destination: 'B')),
      );
      var box = tester.widget<DecoratedBox>(find.byType(DecoratedBox).first);
      expect(
        (box.decoration as BoxDecoration).color,
        KiloColors.light.brandPrimary,
      );

      await tester.pumpWidget(
        host(
          const KTicketHeader(
            origin: 'A',
            destination: 'B',
            accent: AccentHue.prune,
          ),
        ),
      );
      box = tester.widget<DecoratedBox>(find.byType(DecoratedBox).first);
      expect((box.decoration as BoxDecoration).color, const Color(0xFF6B2D5C));
    });

    testWidgets('the motif is woven into it', (tester) async {
      await tester.pumpWidget(
        host(
          const KTicketHeader(
            origin: 'A',
            destination: 'B',
            motif: KPatternMotif.vagues,
          ),
        ),
      );
      expect(
        tester.widget<KPattern>(find.byType(KPattern)).motif,
        KPatternMotif.vagues,
      );
    });
  });

  group('KSectionHeader', () {
    testWidgets('zero and nothing-counted are different', (tester) async {
      // Zero is worth saying out loud on a queue. Null means nobody counted,
      // and a pill reading "0" there is a claim we cannot make.
      await tester.pumpWidget(host(const KSectionHeader('À traiter')));
      expect(find.text('0'), findsNothing);

      await tester.pumpWidget(
        host(const KSectionHeader('À traiter', count: 0)),
      );
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('carries a subtitle and an action', (tester) async {
      await tester.pumpWidget(
        host(
          KSectionHeader(
            'Flotte',
            subtitle: '4 véhicules',
            action: TextButton(onPressed: () {}, child: const Text('Ajouter')),
          ),
        ),
      );
      expect(find.text('4 véhicules'), findsOneWidget);
      expect(find.text('Ajouter'), findsOneWidget);
    });
  });

  group('KPageHeader', () {
    // The reason this component exists: the console set its page titles in
    // the body face at 21 and the back office set the same thing in the serif
    // at 26. A page title is the one place per screen the display face
    // belongs, and a console where every heading is the same face as its
    // table rows is a console where nothing stands out.
    testWidgets('a page title is set in the display face', (tester) async {
      await tester.pumpWidget(host(const KPageHeader('Versements')));

      final style = tester.widget<Text>(find.text('Versements')).style!;
      final kilo = KiloTheme(color: KiloColors.light);
      expect(style.fontFamily, kilo.text.h1.fontFamily);
      expect(style.fontSize, kilo.text.h1.fontSize);
      // And bigger than a section heading, which is the whole distinction
      // between the two components.
      expect(style.fontSize! > kilo.text.h3.fontSize!, isTrue);
    });

    testWidgets('zero and nothing-counted are different here too', (
      tester,
    ) async {
      await tester.pumpWidget(host(const KPageHeader('Versements')));
      expect(find.text('0'), findsNothing);

      await tester.pumpWidget(host(const KPageHeader('Versements', count: 0)));
      expect(find.text('0'), findsOneWidget);
    });

    testWidgets('carries a subtitle and an action', (tester) async {
      await tester.pumpWidget(
        host(
          KPageHeader(
            'Versements',
            subtitle: '3 relevés en attente',
            action: TextButton(onPressed: () {}, child: const Text('Payer')),
          ),
        ),
      );

      expect(find.text('3 relevés en attente'), findsOneWidget);
      expect(find.text('Payer'), findsOneWidget);
    });

    // A page title is one line. An operator whose company name runs long gets
    // an ellipsis, not an overflow stripe across the top of every screen.
    testWidgets('a long title clips rather than overflowing', (tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 240,
            child: KPageHeader(
              'Coopérative des transporteurs de la Bouenza et du Niari',
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('KStat', () {
    testWidgets('the figure is set in the tabular face', (tester) async {
      // A column of figures that does not line up is a column nobody scans.
      await tester.pumpWidget(
        host(const KStat(value: '15 000', label: 'Recette')),
      );
      final style = tester.widget<Text>(find.text('15 000')).style!;
      expect(style.fontFeatures, contains(const FontFeature.tabularFigures()));
      expect(style.fontSize, greaterThan(24));
    });

    testWidgets('a tone colours the figure and never a background', (
      tester,
    ) async {
      // A tile that turns red is a tile somebody stops reading.
      await tester.pumpWidget(
        host(
          const KStat(
            value: '3',
            label: 'Retards',
            tone: Color(0xFFB3332B),
            icon: Icons.warning_amber_rounded,
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text('3')).style!.color,
        const Color(0xFFB3332B),
      );
      expect(find.byType(DecoratedBox), findsNothing);
    });
  });

  group('KSkeleton', () {
    testWidgets('a loading list has the shape of the list', (tester) async {
      await tester.pumpWidget(host(KSkeleton.list(rows: 4)));
      await tester.pump();
      expect(find.byType(KSkeleton), findsNWidgets(4));
    });

    testWidgets('reduce-motion stops the pulse rather than the skeleton', (
      tester,
    ) async {
      // Motion is a battery tax paid by the poorest user. Removing it must
      // not remove the information.
      await tester.pumpWidget(
        host(const KSkeleton(height: 40), noAnimations: true),
      );
      await tester.pump();
      // Scoped: the app scaffold has fades of its own.
      expect(
        find.descendant(
          of: find.byType(KSkeleton),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      expect(find.byType(KSkeleton), findsOneWidget);
    });

    testWidgets('the controller is disposed with the widget', (tester) async {
      // It repeats forever. A leaked one keeps a cheap handset awake.
      await tester.pumpWidget(host(const KSkeleton()));
      await tester.pump();
      await tester.pumpWidget(host(const SizedBox.shrink()));
      expect(tester.takeException(), isNull);
    });
  });
}
