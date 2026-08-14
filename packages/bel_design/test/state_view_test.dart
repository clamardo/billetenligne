import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child, {Size size = const Size(400, 800)}) => MaterialApp(
    theme: KiloTheme.materialTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    ),
  );

  group('KStateView illustrations', () {
    testWidgets('an empty state draws the picture it was given', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const KStateView(KEmpty(art: KArt.noTrips, title: 'Aucun départ')),
        ),
      );
      await tester.pumpAndSettle();

      final art = tester.widget<KIllustration>(find.byType(KIllustration));
      expect(art.art, KArt.noTrips);
    });

    testWidgets('a failure and an offline state each draw their own', (
      tester,
    ) async {
      await tester.pumpWidget(host(const KStateView(KFailed(title: 'Zut'))));
      await tester.pumpAndSettle();
      expect(
        tester.widget<KIllustration>(find.byType(KIllustration)).art,
        KArt.error,
      );

      await tester.pumpWidget(
        host(const KStateView(KOffline(title: 'Hors ligne'))),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<KIllustration>(find.byType(KIllustration)).art,
        KArt.offline,
      );
    });

    testWidgets('the picture is dropped rather than shrunk in a short space', (
      tester,
    ) async {
      // A state squeezed into a sheet or a half-height panel is one where the
      // words are the whole point; a 60 px drawing above them is decoration
      // nobody asked for.
      await tester.pumpWidget(
        host(
          const KStateView(KEmpty(title: 'Rien')),
          size: const Size(400, 180),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(KIllustration), findsNothing);
      expect(find.text('Rien'), findsOneWidget);
    });

    testWidgets('a long state scrolls instead of overflowing', (tester) async {
      await tester.pumpWidget(
        host(
          KStateView(
            KEmpty(
              title: 'Un titre plutôt long qui occupe deux lignes entières',
              body:
                  'Et un paragraphe explicatif qui en occupe trois autres, '
                  'parce que la phrase honnête est rarement la plus courte.',
              actionLabel: 'Rechercher',
              onAction: () {},
            ),
          ),
          size: const Size(320, 360),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('KOffline', () {
    testWidgets('a retry button is drawn only when it has a word on it', (
      tester,
    ) async {
      // It used to draw a real control, correctly sized, with an empty label.
      await tester.pumpWidget(
        host(KStateView(KOffline(title: 'Hors ligne', onRetry: () {}))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(KButton), findsNothing);

      await tester.pumpWidget(
        host(
          KStateView(
            KOffline(
              title: 'Hors ligne',
              retryLabel: 'Réessayer',
              onRetry: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Réessayer'), findsOneWidget);
    });

    testWidgets('offline with something cached shows the content, not a wall', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const KStateView(
            KOffline(title: 'Hors ligne', cached: Text('Mon billet')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Mon billet'), findsOneWidget);
      expect(find.byType(KIllustration), findsNothing);
    });
  });
}
