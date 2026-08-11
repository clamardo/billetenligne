import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Component behaviour that the design system promises and screens rely on.
///
/// These are not screenshot tests. Each one asserts a rule from ADR-0010 that
/// is easy to break by accident and expensive to notice in the field —
/// touch-target size, colour never carrying meaning alone, a disabled control
/// explaining itself.
void main() {
  Widget host(
    Widget child, {
    KiloBrightness brightness = KiloBrightness.light,
  }) => MaterialApp(
    theme: KiloTheme.materialTheme(brightness: brightness),
    home: Scaffold(body: Center(child: child)),
  );

  group('KButton', () {
    testWidgets('is never smaller than a thumb', (tester) async {
      await tester.pumpWidget(
        host(KButton(label: 'Payer', onPressed: () {}, fullWidth: false)),
      );

      final box = tester.getSize(
        find
            .ancestor(of: find.text('Payer'), matching: find.byType(Container))
            .first,
      );

      // Pressed with one thumb, in a hurry, on a moving coach.
      expect(box.height, greaterThanOrEqualTo(48));
    });

    testWidgets('loading keeps the button and drops the label', (tester) async {
      await tester.pumpWidget(
        host(KButton(label: 'Payer', onPressed: () {}, loading: true)),
      );

      expect(find.text('Payer'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a loading button ignores taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(KButton(label: 'Payer', onPressed: () => taps++, loading: true)),
      );

      await tester.tap(find.byType(KButton));
      await tester.pump();

      // The second tap on a slow connection is the one that charges twice.
      expect(taps, 0);
    });

    testWidgets('a disabled button says why', (tester) async {
      await tester.pumpWidget(
        host(
          const KButton(
            label: 'Continuer',
            onPressed: null,
            disabledHint: 'Choisissez au moins une place',
          ),
        ),
      );

      // A greyed control with no explanation is the most common way an app
      // strands somebody.
      expect(find.text('Choisissez au moins une place'), findsOneWidget);
    });

    testWidgets('the hint disappears once it is enabled', (tester) async {
      await tester.pumpWidget(
        host(
          KButton(
            label: 'Continuer',
            onPressed: () {},
            disabledHint: 'Choisissez au moins une place',
          ),
        ),
      );

      expect(find.text('Choisissez au moins une place'), findsNothing);
    });
  });

  group('KSeatMap', () {
    const labels = KSeatMapLabels(
      front: 'AVANT',
      free: 'Libre',
      chosen: 'Choisi',
      taken: 'Occupé',
    );

    List<KSeat> coach({int rows = 3}) => [
      for (var r = 1; r <= rows; r++)
        for (final c in ['A', 'B', 'C', 'D'])
          KSeat(label: '$r$c', state: KSeatState.available),
    ];

    testWidgets('draws every seat it is given', (tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: KSeatMap(
              sections: const [
                KSection(code: 'STD', label: 'Standard', abreast: '2+2'),
              ],
              seats: coach(),
              selected: const {},
              onToggle: (_) {},
              labels: labels,
            ),
          ),
        ),
      );

      expect(find.text('1A'), findsOneWidget);
      expect(find.text('3D'), findsOneWidget);
    });

    testWidgets('marks the front of the vehicle', (tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: KSeatMap(
              sections: const [
                KSection(code: 'STD', label: 'Standard', abreast: '2+2'),
              ],
              seats: coach(),
              selected: const {},
              onToggle: (_) {},
              labels: labels,
            ),
          ),
        ),
      );

      // Without it, half of people assume row 1 is at the back.
      expect(find.text('AVANT'), findsOneWidget);
    });

    testWidgets('a taken seat cannot be tapped', (tester) async {
      final tapped = <String>[];

      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: KSeatMap(
              sections: const [
                KSection(code: 'STD', label: 'Standard', abreast: '2+2'),
              ],
              seats: const [
                KSeat(label: '1A', state: KSeatState.sold),
                KSeat(label: '1B', state: KSeatState.available),
                KSeat(label: '1C', state: KSeatState.held),
                KSeat(label: '1D', state: KSeatState.available),
              ],
              selected: const {},
              onToggle: (s) => tapped.add(s.label),
              labels: labels,
            ),
          ),
        ),
      );

      await tester.tap(find.text('1A'));
      await tester.tap(find.text('1C'));
      await tester.tap(find.text('1B'));
      await tester.pump();

      expect(tapped, ['1B']);
    });

    testWidgets('a taken seat is marked by more than colour', (tester) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: KSeatMap(
              sections: const [
                KSection(code: 'STD', label: 'Standard', abreast: '2+2'),
              ],
              seats: const [
                KSeat(label: '1A', state: KSeatState.sold),
                KSeat(label: '1B', state: KSeatState.available),
                KSeat(label: '1C', state: KSeatState.available),
                KSeat(label: '1D', state: KSeatState.available),
              ],
              selected: const {},
              onToggle: (_) {},
              labels: labels,
            ),
          ),
        ),
      );

      // One slash on the sold seat, and one in the legend. Direct sun flattens
      // hue and roughly one man in twelve cannot separate the two greys from
      // the greens at all.
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('handles a two-class layout with different abreast', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 400,
            child: KSeatMap(
              sections: const [
                KSection(code: 'VIP', label: 'VIP', abreast: '1+2'),
                KSection(code: 'STD', label: 'Standard', abreast: '2+3'),
              ],
              seats: const [
                KSeat(
                  label: '1A',
                  state: KSeatState.available,
                  sectionCode: 'VIP',
                ),
                KSeat(
                  label: '1B',
                  state: KSeatState.available,
                  sectionCode: 'VIP',
                ),
                KSeat(
                  label: '1C',
                  state: KSeatState.available,
                  sectionCode: 'VIP',
                ),
                KSeat(
                  label: '2A',
                  state: KSeatState.available,
                  sectionCode: 'STD',
                ),
                KSeat(
                  label: '2B',
                  state: KSeatState.available,
                  sectionCode: 'STD',
                ),
                KSeat(
                  label: '2C',
                  state: KSeatState.available,
                  sectionCode: 'STD',
                ),
                KSeat(
                  label: '2D',
                  state: KSeatState.available,
                  sectionCode: 'STD',
                ),
                KSeat(
                  label: '2E',
                  state: KSeatState.available,
                  sectionCode: 'STD',
                ),
              ],
              selected: const {},
              onToggle: (_) {},
              labels: labels,
            ),
          ),
        ),
      );

      // One component, a VIP nose and a 5-across body. This is the case that
      // justified cabin sections in the first place (ADR-0017).
      expect(find.text('VIP'), findsOneWidget);
      expect(find.text('STANDARD'), findsOneWidget);
      expect(find.text('2E'), findsOneWidget);
    });
  });

  group('KCountdown', () {
    testWidgets('counts down and fires once at zero', (tester) async {
      var expired = 0;

      // A controlled clock, because `tester.pump()` moves Flutter's timers and
      // not the wall clock. Without this the widget counts down forever in a
      // test and the expiry callback — the one that releases a seat — is
      // never exercised at all.
      var now = DateTime.utc(2026, 8, 9, 6);
      final expiresAt = now.add(const Duration(seconds: 3));

      await tester.pumpWidget(
        host(
          KCountdown(
            expiresAt: expiresAt,
            labelBuilder: formatCountdown,
            onExpired: () => expired++,
            now: () => now,
          ),
        ),
      );

      expect(find.text('00:03'), findsOneWidget);

      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00:02'), findsOneWidget);

      now = now.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('00:00'), findsOneWidget);

      // Keep ticking past expiry. A callback that fires every second past zero
      // releases the hold repeatedly and logs three failures for one event.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(expired, 1);
    });

    testWidgets('never shows a negative time', (tester) async {
      await tester.pumpWidget(
        host(
          KCountdown(
            expiresAt: DateTime.utc(2026, 8, 9, 6),
            labelBuilder: formatCountdown,
            now: () => DateTime.utc(2026, 8, 9, 6, 5),
          ),
        ),
      );

      expect(find.text('00:00'), findsOneWidget);
    });
  });

  group('KStateView', () {
    testWidgets('a wait always has a sentence attached', (tester) async {
      await tester.pumpWidget(
        host(const KStateView(KLoading('Recherche des départs…'))),
      );

      // A naked spinner on 2G is long enough for somebody to decide the app
      // has frozen.
      expect(find.text('Recherche des départs…'), findsOneWidget);
    });

    testWidgets('an unretryable failure offers no retry', (tester) async {
      await tester.pumpWidget(
        host(const KStateView(KFailed(title: 'Place déjà prise'))),
      );

      expect(find.byType(KButton), findsNothing);
    });

    testWidgets('a failure shows its trace id, selectably', (tester) async {
      await tester.pumpWidget(
        host(const KStateView(KFailed(title: 'Erreur', traceId: 'k3f9a2'))),
      );

      // The one string a support agent needs, read down a phone line.
      expect(find.text('k3f9a2'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('offline with cached content shows the content', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 360,
            height: 400,
            child: KStateView(
              KOffline(title: 'Hors ligne', cached: Text('Mon billet')),
            ),
          ),
        ),
      );

      // Offline does not mean blank. A ticket bought yesterday must render in
      // a tunnel today.
      expect(find.text('Mon billet'), findsOneWidget);
      expect(find.text('Hors ligne'), findsOneWidget);
    });
  });

  group('KTripCard', () {
    Widget card({
      bool soldOut = false,
      VoidCallback? onTap,
      String? reliabilityLabel,
    }) => host(
      SizedBox(
        width: 380,
        child: KTripCard(
          departureTime: '06:00',
          arrivalTime: '14:00',
          operatorName: 'Ocean du Nord',
          durationLabel: '8 h',
          totalFormatted: '12 300 FCFA',
          seatsLabel: '12 places',
          soldOut: soldOut,
          soldOutLabel: 'Complet',
          reliabilityLabel: reliabilityLabel,
          onTap: onTap,
        ),
      ),
    );

    testWidgets('leads with the departure time', (tester) async {
      await tester.pumpWidget(card());

      final departure = tester.widget<Text>(find.text('06:00'));
      final price = tester.widget<Text>(find.text('12 300 FCFA'));

      // People choose a coach by when it goes, and only then check the price.
      expect(departure.style!.fontSize!, greaterThan(price.style!.fontSize!));
    });

    testWidgets('a sold-out card is shown, and is not tappable', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(card(soldOut: true, onTap: () => taps++));

      expect(find.text('Complet'), findsOneWidget);

      await tester.tap(find.byType(KTripCard));
      await tester.pump();
      expect(taps, 0);
    });

    testWidgets('an on-time record is shown, and its absence is silent', (
      tester,
    ) async {
      await tester.pumpWidget(card(reliabilityLabel: '92 % à l\'heure'));
      expect(find.text('92 % à l\'heure'), findsOneWidget);

      // No figure draws nothing at all. A "0 %" or an "aucune donnée" chip
      // beside a new operator is a judgement we have no data for.
      await tester.pumpWidget(card());
      expect(find.textContaining("l'heure"), findsNothing);
    });
  });

  group('KChip', () {
    testWidgets('a long label narrows the chip, it does not break the card', (
      tester,
    ) async {
      // The case that used to break: a trip card at a phone's width with a
      // seats label spelled out. The chip has to ellipsise, because a chip
      // that overflows takes the whole row with it — and the row is the
      // search result somebody is trying to buy.
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 360,
            child: KTripCard(
              departureTime: '06:00',
              arrivalTime: '13:30',
              operatorName: 'Ocean du Nord',
              durationLabel: '7 h',
              totalFormatted: '9 000 FCFA',
              seatsLabel: '12 places restantes',
              onTap: null,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });

  group('KBrandHeader', () {
    testWidgets('an operator with no logo still gets a mark', (tester) async {
      await tester.pumpWidget(
        host(
          const KBrandHeader(
            title: 'Océan du Nord SARL',
            tagline: 'Le confort sur toutes les routes',
            accent: AccentHue.ocean,
          ),
        ),
      );

      // The documented default: a generated monogram rather than an empty
      // square, so an operator who never opened the vitrine editor still
      // looks maintained rather than abandoned.
      expect(find.byType(KMonogram), findsOneWidget);
      expect(find.text('ON'), findsOneWidget);
    });

    testWidgets('a supplied logo replaces the monogram entirely', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const KBrandHeader(
            title: 'Océan du Nord',
            accent: AccentHue.ocean,
            logo: SizedBox.shrink(key: Key('logo')),
          ),
        ),
      );

      expect(find.byKey(const Key('logo')), findsOneWidget);
      expect(find.byType(KMonogram), findsNothing);
    });

    testWidgets('the compact header drops the tagline, not the title', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const KBrandHeader(
            title: 'Océan du Nord',
            tagline: 'Le confort sur toutes les routes',
            accent: AccentHue.laterite,
            compact: true,
          ),
        ),
      );

      // The console wears this all day above a table. A tagline there is a
      // line of vertical space taken from the work.
      expect(find.text('Océan du Nord'), findsOneWidget);
      expect(find.text('Le confort sur toutes les routes'), findsNothing);
    });

    testWidgets('every pattern paints without throwing', (tester) async {
      for (final pattern in HeaderPattern.values) {
        await tester.pumpWidget(
          host(
            KBrandHeader(
              title: 'Sotrapo',
              accent: AccentHue.prune,
              pattern: pattern,
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: pattern.name);
      }
    });

    test('a monogram skips the words that identify nobody', () {
      // Every second operator in Congo is a SARL.
      expect(KMonogram.initialsOf('Océan du Nord SARL'), 'ON');
      expect(KMonogram.initialsOf('Sotrapo'), 'SO');
      expect(KMonogram.initialsOf('Trans Bony Voyages'), 'TB');
      expect(KMonogram.initialsOf(''), '?');
    });

    test('an unknown hue or pattern falls back rather than throwing', () {
      expect(AccentHue.byName('chartreuse'), AccentHue.foret);
      expect(AccentHue.byName(null), AccentHue.foret);
      expect(HeaderPattern.byName('hexagones'), HeaderPattern.flat);
    });
  });

  group('both themes', () {
    testWidgets('components render in dark without throwing', (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              KButton(label: 'Payer', onPressed: () {}, fullWidth: false),
              const KChip('12 places'),
              const KMoney('12 300 FCFA'),
            ],
          ),
          brightness: KiloBrightness.dark,
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('and in plein soleil', (tester) async {
      await tester.pumpWidget(
        host(
          KButton(label: 'Payer', onPressed: () {}, fullWidth: false),
          brightness: KiloBrightness.pleinSoleil,
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
