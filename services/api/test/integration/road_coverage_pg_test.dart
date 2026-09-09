@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// J5 — the dispatcher's coverage figure.
///
/// The scanner suite proves the conductor is *asked*. This file proves the
/// other half: that the number an office looks at afterwards is counted from
/// `departure_checkpoints` and not from anything that can drift away from it.
///
/// That distinction is the whole point of the slice. A counter on the
/// departure row would be maintained by whichever code path wrote the last
/// checkpoint, and would be wrong the first time a row arrived by any other
/// road — a backfill, a support fix, a second handset syncing an hour late.
/// A coverage figure that is quietly wrong a fortnight in is a figure nobody
/// in the office chases a coach with.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorConsole console;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// A departure on a road with [stops] named waypoints.
  Future<({String id, List<Waypoint> road})> run({int stops = 3}) async {
    final routeId = await fixture.route(
      code: 'COV-${DateTime.now().microsecondsSinceEpoch}',
      destination: 'PNR',
    );
    await fixture.stopsOn(routeId, [
      for (var i = 0; i < stops; i++)
        (city: const ['OYO', 'DOL', 'NKY'][i], offsetMinutes: 90 * (i + 1)),
    ]);
    final id = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(hours: 2),
      onRoute: routeId,
    );
    return (
      id: id,
      road:
          (await console.waypoints(
            operatorId: PgFixture.operatorId,
            departureId: id,
          ))!,
    );
  }

  Future<DepartureBoardRow> rowFor(String departureId) async {
    final board = await console.board(
      operatorId: PgFixture.operatorId,
      localDate: await fixture.localDayOf(departureId),
    );
    return board.firstWhere((r) => r.id == departureId);
  }

  test('a road with waypoints reports how many of them there are', () async {
    final trip = await run();

    final row = await rowFor(trip.id);

    expect(row.stops, 3);
    expect(row.confirmedStops, 0, reason: 'nobody has confirmed anything yet');
  });

  test('a direct run reports no waypoints rather than a zero', () async {
    final trip = await run(stops: 0);

    final row = await rowFor(trip.id);

    // Brazzaville to Pointe-Noire direct is a real road. Nought out of nought
    // is the honest answer, and the console draws no column for it — a
    // coverage figure on every direct run is how the real ones stop being
    // noticed.
    expect(row.stops, 0);
    expect(row.confirmedStops, 0);
  });

  test('a confirmation through the console is counted', () async {
    final trip = await run();

    await console.confirmPassage(
      operatorId: PgFixture.operatorId,
      departureId: trip.id,
      reportedByUserId: null,
      passages: [
        PassageReport(
          stopId: trip.road.first.stopId,
          passedAt: DateTime.now().toUtc(),
          deviceId: 'handset-1',
        ),
      ],
    );

    expect((await rowFor(trip.id)).confirmedStops, 1);
  });

  test('a checkpoint written by anything else is counted too', () async {
    final trip = await run();

    // Not through the console. This is the case a counter maintained by the
    // upload path would miss, and the reason the figure is a `count(*)`.
    await fixture.checkpoint(
      departureId: trip.id,
      stopId: trip.road[1].stopId,
      passedAt: DateTime.now().toUtc(),
    );

    expect((await rowFor(trip.id)).confirmedStops, 1);
  });

  test('confirming the same place twice is still one stop', () async {
    final trip = await run();
    final at = DateTime.now().toUtc();

    await console.confirmPassage(
      operatorId: PgFixture.operatorId,
      departureId: trip.id,
      reportedByUserId: null,
      passages: [
        PassageReport(stopId: trip.road.first.stopId, passedAt: at),
      ],
    );
    // The outbox emptying a second time, which is the normal case on this
    // network rather than an odd one.
    await console.confirmPassage(
      operatorId: PgFixture.operatorId,
      departureId: trip.id,
      reportedByUserId: null,
      passages: [
        PassageReport(
          stopId: trip.road.first.stopId,
          passedAt: at.add(const Duration(minutes: 5)),
        ),
      ],
    );

    expect(
      (await rowFor(trip.id)).confirmedStops,
      1,
      reason: 'first tap wins, by primary key',
    );
  });

  test('coverage belongs to the departure, not to the road', () async {
    // Two departures on one road: this morning's coach confirmed Oyo,
    // tomorrow's has not left the yard. A count that keyed on the route
    // rather than the run would report tomorrow as already reporting.
    final routeId = await fixture.route(
      code: 'COV2-${DateTime.now().microsecondsSinceEpoch}',
      destination: 'PNR',
    );
    await fixture.stopsOn(routeId, const [
      (city: 'OYO', offsetMinutes: 150),
      (city: 'DOL', offsetMinutes: 300),
    ]);
    final morning = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(hours: 2),
      onRoute: routeId,
    );
    final tomorrow = await fixture.departure(
      seatLabels: const ['1A'],
      fromNow: const Duration(hours: 26),
      onRoute: routeId,
    );

    final road = (await console.waypoints(
      operatorId: PgFixture.operatorId,
      departureId: morning,
    ))!;
    await fixture.checkpoint(
      departureId: morning,
      stopId: road.first.stopId,
      passedAt: DateTime.now().toUtc(),
    );

    expect((await rowFor(morning)).confirmedStops, 1);
    expect((await rowFor(tomorrow)).confirmedStops, 0);
    expect((await rowFor(tomorrow)).stops, 2);
  });

  test('the seat figures survive the two new counts', () async {
    // The board fans `seats` out with a LEFT JOIN and aggregates over it.
    // Adding the coverage counts as two more joins would have multiplied
    // sold and held against them; they are scalar subqueries for exactly
    // that reason, and this is the assertion that says so.
    final routeId = await fixture.route(
      code: 'COV3-${DateTime.now().microsecondsSinceEpoch}',
      destination: 'PNR',
    );
    await fixture.stopsOn(routeId, const [
      (city: 'OYO', offsetMinutes: 150),
      (city: 'DOL', offsetMinutes: 300),
    ]);
    final id = await fixture.departure(
      seatLabels: const ['1A', '1B', '1C'],
      fromNow: const Duration(hours: 3),
      onRoute: routeId,
    );

    final row = await rowFor(id);

    expect(row.capacity, 3);
    expect(row.sold, 0);
    expect(row.held, 0);
    expect(row.available, 3);
    expect(row.stops, 2);
  });
}
