import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_scanner/src/application/road_progress.dart';
import 'package:bel_scanner/src/infrastructure/memory_redemption_log.dart';
import 'package:bel_scanner/src/presentation/widgets/due_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// J5 — confirming a stop is *asked for*, not hoped for.
///
/// The road sheet has always been able to record a passage. Nobody was ever
/// asked to open it, which is why a coach whose conductor never taps shows an
/// honest estimate for four hours — and honest is not the same as useful.
///
/// Two properties are worth more than the rest of this file put together:
///
///   * the ask comes from **the timetable**, not from a clock the app
///     started. A handset switched on at the roadside three hours into the
///     run is asked about Dolisie immediately; one switched on in the yard is
///     asked about nothing;
///   * it is asked **twice at most**. §5.3 refuses the punitive version of
///     this on purpose: a conductor who cannot get past a prompt at a coach
///     door puts the handset in a drawer, and the pressure to report belongs
///     on the dispatcher's screen as a coverage figure.
void main() {
  /// 06:00 out of Brazzaville, the way the timetable has it.
  final departsAt = DateTime.utc(2026, 8, 15, 6);

  const theRoad = [
    WaypointDto(stopId: 'stop-kinkala', name: 'Kinkala', offsetMinutes: 90),
    WaypointDto(stopId: 'stop-nkayi', name: 'Nkayi', offsetMinutes: 300),
    WaypointDto(stopId: 'stop-dolisie', name: 'Dolisie', offsetMinutes: 400),
  ];

  RoadProgress at(
    DateTime now, {
    MemoryCheckpointLog? outbox,
    List<WaypointDto> waypoints = theRoad,
  }) => RoadProgress(
    road: waypoints,
    outbox: outbox ?? MemoryCheckpointLog(),
    clock: FixedClock(now),
    departsAt: departsAt,
    deviceId: 'handset-1',
  );

  group('the ask comes from the timetable', () {
    test('nothing is due in the yard', () {
      // Ten minutes before the coach leaves. The first waypoint is an hour and
      // a half of road away, and asking now would train the conductor to wave
      // the prompt away before it has ever meant anything.
      expect(at(departsAt.subtract(const Duration(minutes: 10))).due, isNull);
    });

    test('nothing is due while the coach is still short of the first stop', () {
      expect(at(departsAt.add(const Duration(minutes: 89))).due, isNull);
    });

    test('the stop falls due at its own scheduled minute', () {
      final due = at(departsAt.add(const Duration(minutes: 90))).due;
      expect(due?.name, 'Kinkala');
    });

    test('a handset switched on three hours in is asked at once', () {
      // The whole reason the rule is `departsAt + offset` and not "so many
      // minutes since this screen opened": the conductor's phone died at
      // Kinkala and came back at Nkayi, and the fact somebody at the far end
      // is waiting for is three hours old.
      final due = at(departsAt.add(const Duration(minutes: 305))).due;
      expect(due?.name, 'Kinkala', reason: 'the earliest one still missing');
    });

    test('a confirmed stop is never asked about again', () {
      final road = at(departsAt.add(const Duration(minutes: 305)));
      road.confirm('stop-kinkala');

      expect(road.due?.name, 'Nkayi');
    });

    test('a run with no intermediate stops asks nothing', () {
      expect(
        at(departsAt.add(const Duration(hours: 9)), waypoints: const []).due,
        isNull,
      );
    });
  });

  group('waved away', () {
    test('a waved prompt is quiet until the re-offer is actually due', () {
      final start = departsAt.add(const Duration(minutes: 95));
      final clock = _Moving(start);
      final road = RoadProgress(
        road: theRoad,
        outbox: MemoryCheckpointLog(),
        clock: clock,
        departsAt: departsAt,
        deviceId: 'handset-1',
      );

      expect(road.due?.name, 'Kinkala');
      road.wave('stop-kinkala');
      expect(road.due, isNull, reason: 'not on the very next frame');

      // The re-offer is a second occasion, not the same one carried on. Five
      // minutes later the conductor is still stepping people off at Kinkala.
      clock.instant = start.add(const Duration(minutes: 5));
      expect(road.due, isNull);
    });

    test('the re-offer arrives, and it is the last one', () {
      final start = departsAt.add(const Duration(minutes: 95));
      final clock = _Moving(start);

      // One RoadProgress across the whole afternoon, because what is under
      // test is what it remembers. Rebuilding it on the same outbox would
      // keep the confirmations and lose the count of times somebody was
      // asked, which is the half that matters here.
      final road = RoadProgress(
        road: const [
          WaypointDto(
            stopId: 'stop-kinkala',
            name: 'Kinkala',
            offsetMinutes: 90,
          ),
        ],
        outbox: MemoryCheckpointLog(),
        clock: clock,
        departsAt: departsAt,
        deviceId: 'handset-1',
      );

      expect(road.due?.name, 'Kinkala');
      road.wave('stop-kinkala');
      expect(road.due, isNull);

      clock.instant = start.add(RoadProgress.waveOff);
      expect(road.due?.name, 'Kinkala', reason: 'the one re-offer');

      road.wave('stop-kinkala');
      clock.instant = start.add(const Duration(hours: 4));
      expect(
        road.due,
        isNull,
        reason: 'asked twice and then never again — §5.3',
      );
    });
  });

  group('the strip', () {
    late TranslationCatalog catalog;
    setUpAll(() async => catalog = await loadTestCatalog());

    Future<RoadProgress> pump(WidgetTester tester) async {
      final road = at(departsAt.add(const Duration(minutes: 95)));
      final point = road.due!;

      await tester.pumpWidget(
        scannerHarness(
          catalog,
          Scaffold(
            body: DuePrompt(
              point: point,
              onConfirm: () => road.confirm(point.stopId),
              onWave: () => road.wave(point.stopId),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return road;
    }

    testWidgets('names the place, and both answers are one tap', (
      tester,
    ) async {
      await pump(tester);

      expect(find.text('Passé Kinkala ?'), findsOneWidget);
      expect(find.text('Oui'), findsOneWidget);
      // A refusal that costs more than the answer is not a question. It is
      // beside "Oui", the same size, one tap.
      expect(find.text('Pas encore'), findsOneWidget);
    });

    testWidgets('yes records the passage', (tester) async {
      final road = await pump(tester);

      await tester.tap(find.text('Oui'));
      await tester.pumpAndSettle();

      expect(road.lastConfirmed?.name, 'Kinkala');
      expect(road.pendingCount, 1, reason: 'queued, like every other write');
    });

    testWidgets('not yet records nothing at all', (tester) async {
      final road = await pump(tester);

      await tester.tap(find.text('Pas encore'));
      await tester.pumpAndSettle();

      expect(road.lastConfirmed, isNull);
      expect(road.pendingCount, 0);
      expect(road.due, isNull, reason: 'quiet until the one re-offer');
    });
  });
}

/// A clock a test moves by hand, so one [RoadProgress] can live through a
/// whole afternoon.
final class _Moving implements Clock {
  _Moving(this.instant);
  DateTime instant;

  @override
  DateTime now() => instant;
}
