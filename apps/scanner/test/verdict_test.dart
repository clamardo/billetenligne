import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_scanner/src/presentation/widgets/verdict_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the conductor reads at arm's length, in the sun, in the second before
/// they wave somebody on.
void main() {
  Future<void> pump(WidgetTester tester, VerificationOutcome outcome) =>
      tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(
            brightness: KiloBrightness.pleinSoleil,
          ),
          home: VerdictScreen(outcome: outcome, onDismiss: () {}),
        ),
      );

  final payload = TicketPayload(
    bookingRef: 'ZZ1188',
    seatLabel: '2C',
    departureId: 'dep-bzv-pnr-0600',
    departsAt: DateTime.utc(2026, 8, 15, 6),
    routeCode: 'BZV>PNR',
    operatorCode: 'ODN',
    passengerName: 'Marie Kimbembe',
    keyId: 1,
  );

  testWidgets(
    'a passenger riding a piece of the road says where they get off',
    (tester) async {
      await pump(
        tester,
        VerificationOutcome(
          result: VerificationResult.valid,
          payload: payload,
          entry: ManifestEntry(
            bookingRef: 'ZZ1188',
            seatLabel: '2C',
            passengerName: 'Marie Kimbembe',
            rotatingSecret: [1, 2, 3],
            boardsAt: 'BZV',
            alightsAt: 'DOL',
          ),
        ),
      );

      expect(find.text('Descend à DOL'), findsOneWidget);
    },
  );

  testWidgets('a whole-road ticket says nothing extra', (tester) async {
    await pump(
      tester,
      VerificationOutcome(
        result: VerificationResult.valid,
        payload: payload,
        entry: ManifestEntry(
          bookingRef: 'ZZ1188',
          seatLabel: '2C',
          passengerName: 'Marie Kimbembe',
          rotatingSecret: [1, 2, 3],
        ),
      ),
    );

    // The two towns on a whole-road ticket are the two towns everybody at
    // this door already knows. A line that is always there is a line nobody
    // reads.
    expect(find.textContaining('Descend à'), findsNothing);
  });
}
