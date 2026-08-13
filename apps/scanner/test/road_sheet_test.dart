import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_scanner/src/application/road_progress.dart';
import 'package:bel_scanner/src/infrastructure/memory_redemption_log.dart';
import 'package:bel_scanner/src/presentation/widgets/road_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// *Où sommes-nous ?* — the one screen behind ADR-0014's second tier.
///
/// What is being tested is not a list. It is that a conductor on a coach with
/// no signal can publish a fact somebody at the far end is waiting for, and
/// that the app never lets them publish it twice or take it back.
void main() {
  final now = DateTime.utc(2026, 8, 15, 10, 42);

  const road = [
    WaypointDto(stopId: 'stop-kinkala', name: 'Kinkala', offsetMinutes: 90),
    WaypointDto(stopId: 'stop-nkayi', name: 'Nkayi', offsetMinutes: 300),
    WaypointDto(stopId: 'stop-dolisie', name: 'Dolisie', offsetMinutes: 400),
  ];

  Future<RoadProgress> pump(
    WidgetTester tester, {
    List<WaypointDto> waypoints = road,
    MemoryCheckpointLog? outbox,
  }) async {
    final progress = RoadProgress(
      road: waypoints,
      outbox: outbox ?? MemoryCheckpointLog(),
      clock: FixedClock(now),
      deviceId: 'handset-1',
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: KiloTheme.materialTheme(brightness: KiloBrightness.pleinSoleil),
        home: Scaffold(body: RoadSheet(road: progress)),
      ),
    );
    await tester.pumpAndSettle();
    return progress;
  }

  testWidgets('the road is the list, in the order it is driven', (
    tester,
  ) async {
    await pump(tester);

    // Names, not coordinates. The conductor is on the RN1 with no signal, and
    // a map would be tiles that cannot load.
    expect(find.text('Kinkala'), findsOneWidget);
    expect(find.text('Nkayi'), findsOneWidget);
    expect(find.text('Dolisie'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('one tap confirms a place, and says the time it was', (
    tester,
  ) async {
    final outbox = MemoryCheckpointLog();
    await pump(tester, outbox: outbox);

    await tester.tap(find.text('Nkayi'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.textContaining('Passé à'), findsOneWidget);
    // The device's clock, queued for the next window with signal.
    expect(outbox.pending().single.stopId, 'stop-nkayi');
    expect(outbox.pending().single.passedAt, now);
  });

  testWidgets('a confirmed place cannot be taken back', (tester) async {
    final outbox = MemoryCheckpointLog();
    await pump(tester, outbox: outbox);

    await tester.tap(find.text('Nkayi'));
    await tester.pumpAndSettle();
    // Tapping it again is not an undo and must not behave like one:
    // confirming a waypoint publishes a fact somebody may already have left
    // for the station on.
    await tester.tap(find.text('Nkayi'));
    await tester.pumpAndSettle();

    expect(outbox.confirmed(), hasLength(1));
    expect(outbox.confirmed()['stop-nkayi'], now);
  });

  testWidgets('the sheet stays open for a run of taps', (tester) async {
    final outbox = MemoryCheckpointLog();
    await pump(tester, outbox: outbox);

    // Back on signal after three hours, a conductor confirms two or three
    // places in a row. A sheet that closed after each one would make that
    // three trips through the footer.
    await tester.tap(find.text('Kinkala'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nkayi'));
    await tester.pumpAndSettle();

    expect(find.byType(RoadSheet), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(outbox.pending(), hasLength(2));
  });

  testWidgets('a place the server already knows about is drawn as done', (
    tester,
  ) async {
    final outbox = MemoryCheckpointLog();
    final progress = await pump(
      tester,
      outbox: outbox,
      waypoints: [
        road.first,
        WaypointDto(
          stopId: 'stop-dolisie',
          name: 'Dolisie',
          offsetMinutes: 400,
          passedAt: DateTime.utc(2026, 8, 15, 9),
        ),
      ],
    );

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(progress.lastConfirmed?.name, 'Dolisie');
    // It came *from* the server, so it is not news to it.
    expect(outbox.pending(), isEmpty);
  });
}
