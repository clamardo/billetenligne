@Tags(['integration'])
library;

import 'package:bel_api/src/application/search_departures.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_departure_catalogue.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// J8 — sort, then filter, against the SQL that has to hold the order.
///
/// The interesting claim is not that a list comes back sorted. It is §6.2:
/// **search pagination here is a keyset, and a keyset is defined against an
/// order.** A cursor minted under `earliest` names a position that does not
/// exist under `cheapest`, so the sort travels *inside* the cursor and a
/// disagreement is refused rather than re-sorted. Silently re-sorting produces
/// duplicate and missing rows across a page boundary, which reads to everybody
/// as the inventory being wrong.
///
/// Everything here runs on one day far enough out that no other file in this
/// shared database has put a coach on it.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresDepartureCatalogue catalogue;
  late SearchDepartures search;
  late DateTime day;

  /// The five coaches, and the order each sort should put them in.
  late String cheapSlowLate;
  late String dearFastEarly;
  late String midMidMid;
  late String cheapFastNoon;
  late String dearSlowEvening;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 6);
    catalogue = PostgresDepartureCatalogue(
      db,
      timeZone: Market.current.timeZone,
    );
    search = SearchDepartures(catalogue: catalogue, pageSize: 20);

    // Deliberately not in any of the three orders as written, so a test that
    // passed by insertion order would have to be a coincidence three times.
    dearFastEarly = await fixture.departureAtLocalTime(
      seatLabels: const ['1A'],
      daysAhead: 41,
      localHour: 5,
      fareMinor: 20000,
      durationHours: 5,
    );
    cheapSlowLate = await fixture.departureAtLocalTime(
      seatLabels: const ['1A'],
      daysAhead: 41,
      localHour: 21,
      fareMinor: 8000,
      durationHours: 11,
    );
    cheapFastNoon = await fixture.departureAtLocalTime(
      seatLabels: const ['1A'],
      daysAhead: 41,
      localHour: 12,
      fareMinor: 9000,
      durationHours: 6,
    );
    dearSlowEvening = await fixture.departureAtLocalTime(
      seatLabels: const ['1A'],
      daysAhead: 41,
      localHour: 19,
      fareMinor: 18000,
      durationHours: 10,
    );
    midMidMid = await fixture.departureAtLocalTime(
      seatLabels: const ['1A'],
      daysAhead: 41,
      localHour: 9,
      fareMinor: 12000,
      durationHours: 8,
    );

    day = await fixture.localDateAheadOfToday(41);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  /// Only the coaches this file put on the road. The database is shared, so
  /// every assertion filters to these five and asserts on their *relative*
  /// order — which is the claim, and is true whoever else is selling that day.
  List<String> mine() => [
    dearFastEarly,
    midMidMid,
    cheapFastNoon,
    dearSlowEvening,
    cheapSlowLate,
  ];

  SearchDeparturesQuery ask({
    TripSort sort = TripSort.earliest,
    String? cursor,
    int? limit,
    int? fromHour,
    int? toHour,
    int? maxFare,
    String? operatorId,
  }) => SearchDeparturesQuery(
    originCity: 'BZV',
    destinationCity: 'PNR',
    date: day,
    sort: sort,
    cursor: cursor,
    limit: limit,
    departFromHour: fromHour,
    departToHour: toHour,
    maxFareMinor: maxFare,
    operatorId: operatorId,
  );

  /// The ids this file created, in the order the server returned them.
  Future<List<String>> ordered(SearchDeparturesQuery query) async {
    final page = await search(query, now: DateTime.now().toUtc());
    final rows = page.valueOrNull;
    expect(rows, isNotNull, reason: page.failureOrNull?.code);
    return [
      for (final d in rows!.departures)
        if (mine().contains(d.id)) d.id,
    ];
  }

  /// Every page walked to the end, with the cursor the server handed back.
  Future<List<String>> walk(TripSort sort, {int limit = 2}) async {
    final seen = <String>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final result = await search(
        ask(sort: sort, cursor: cursor, limit: limit),
        now: DateTime.now().toUtc(),
      );
      final value = result.valueOrNull;
      expect(value, isNotNull, reason: result.failureOrNull?.code);
      for (final d in value!.departures) {
        if (mine().contains(d.id)) seen.add(d.id);
      }
      cursor = value.nextCursor;
      if (cursor == null) return seen;
    }
    fail('the cursor never ran out');
  }

  group('the three orders', () {
    test('earliest is the departure time', () async {
      expect(await ordered(ask()), [
        dearFastEarly,
        midMidMid,
        cheapFastNoon,
        dearSlowEvening,
        cheapSlowLate,
      ]);
    });

    test('cheapest is the fare on the row', () async {
      expect(await ordered(ask(sort: TripSort.cheapest)), [
        cheapSlowLate,
        cheapFastNoon,
        midMidMid,
        dearSlowEvening,
        dearFastEarly,
      ]);
    });

    test('fastest is how long the traveller is on the coach', () async {
      // Not the arrival time, and this is the case that tells them apart: the
      // 21:00 arrives last and is the slowest; the 05:00 arrives first and is
      // the quickest — but the 12:00 is quicker than the 09:00 despite
      // arriving later.
      expect(await ordered(ask(sort: TripSort.fastest)), [
        dearFastEarly,
        cheapFastNoon,
        midMidMid,
        dearSlowEvening,
        cheapSlowLate,
      ]);
    });
  });

  group('the cursor carries the order', () {
    test('paging under each sort produces every row exactly once', () async {
      for (final sort in TripSort.values) {
        final walked = await walk(sort);
        expect(walked, await ordered(ask(sort: sort)), reason: sort.name);
        expect(walked.toSet(), hasLength(walked.length), reason: sort.name);
      }
    });

    test('a cursor minted under one sort is refused under another', () async {
      final first = await search(
        ask(sort: TripSort.cheapest, limit: 2),
        now: DateTime.now().toUtc(),
      );
      final cursor = first.valueOrNull!.nextCursor!;

      final crossed = await search(
        ask(sort: TripSort.fastest, cursor: cursor),
        now: DateTime.now().toUtc(),
      );

      // Refused, not re-sorted. A re-sort here would answer with rows the
      // traveller has already seen and skip ones they never will.
      expect(crossed.failureOrNull, isA<CursorSortChanged>());
      expect(
        crossed.failureOrNull!.code,
        ErrorCode.searchCursorSortChanged,
      );
    });

    test('and the same cursor under its own sort still works', () async {
      final first = await search(
        ask(sort: TripSort.cheapest, limit: 2),
        now: DateTime.now().toUtc(),
      );
      final cursor = first.valueOrNull!.nextCursor!;

      final second = await search(
        ask(sort: TripSort.cheapest, cursor: cursor),
        now: DateTime.now().toUtc(),
      );

      expect(second.valueOrNull, isNotNull);

      // Asserted as a continuation rather than against a fixed row: this day
      // is shared with whatever else the suite has put on it, so the page
      // boundary does not land on one of ours. What must hold either way is
      // that the second page picks up exactly where the first stopped —
      // nothing repeated, nothing skipped.
      List<String> minesOf(SearchPage page) => [
        for (final d in page.departures)
          if (mine().contains(d.id)) d.id,
      ];

      final walked = [
        ...minesOf(first.valueOrNull!),
        ...minesOf(second.valueOrNull!),
      ];
      final whole = await ordered(ask(sort: TripSort.cheapest));

      expect(walked.toSet(), hasLength(walked.length));
      expect(whole.take(walked.length), walked);
    });

    test('a cursor this server never minted is refused', () async {
      final result = await search(
        ask(cursor: 'not-a-cursor'),
        now: DateTime.now().toUtc(),
      );
      expect(result.failureOrNull, isA<UnreadableCursor>());
    });
  });

  group('the three filters', () {
    test('a departure window, read in the market\'s own hours', () async {
      // 09:00 to 20:00 local: the 05:00 and the 21:00 fall out, the rest stay.
      expect(await ordered(ask(fromHour: 9, toHour: 20)), [
        midMidMid,
        cheapFastNoon,
        dearSlowEvening,
      ]);
    });

    test('an open-ended window', () async {
      expect(await ordered(ask(fromHour: 19)), [
        dearSlowEvening,
        cheapSlowLate,
      ]);
    });

    test('a price ceiling is the fare, not the total', () async {
      // 12 000 exactly. The 09:00 is priced at the figure typed and stays —
      // a ceiling that quietly added our service fee would drop it.
      expect(await ordered(ask(maxFare: 12000)), [
        midMidMid,
        cheapFastNoon,
        cheapSlowLate,
      ]);
    });

    test('filters compose with the sort, and the cursor survives', () async {
      final walked = <String>[];
      String? cursor;
      for (var page = 0; page < 10; page++) {
        final result = await search(
          ask(
            sort: TripSort.cheapest,
            maxFare: 12000,
            limit: 1,
            cursor: cursor,
          ),
          now: DateTime.now().toUtc(),
        );
        final value = result.valueOrNull;
        expect(value, isNotNull, reason: result.failureOrNull?.code);
        for (final d in value!.departures) {
          if (mine().contains(d.id)) walked.add(d.id);
        }
        cursor = value.nextCursor;
        if (cursor == null) break;
      }

      expect(walked, [cheapSlowLate, cheapFastNoon, midMidMid]);
    });

    test('another operator\'s coaches are not this operator\'s', () async {
      final other = await fixture.secondOperator();

      expect(await ordered(ask(operatorId: other)), isEmpty);
      expect(
        await ordered(ask(operatorId: PgFixture.operatorId)),
        hasLength(mine().length),
      );
    });
  });

  group('what a filter must never hide', () {
    test('a sold-out coach stays on the list, and says so', () async {
      final full = await fixture.departureAtLocalTime(
        seatLabels: const ['1A'],
        daysAhead: 42,
        localHour: 6,
        fareMinor: 10000,
      );
      await fixture.sellSeat(departureId: full, seatLabel: '1A');

      final result = await search(
        SearchDeparturesQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          date: await fixture.localDateAheadOfToday(42),
          operatorId: PgFixture.operatorId,
          maxFareMinor: 15000,
          sort: TripSort.cheapest,
        ),
        now: DateTime.now().toUtc(),
      );

      // §6.1: filters narrow what is **offered**, never what is **knowable**.
      // Seeing that the 06:00 is full is how somebody decides to take the
      // 05:30 rather than come back tomorrow.
      final row = result.valueOrNull!.departures.firstWhere(
        (d) => d.id == full,
      );
      expect(row.seatsAvailable, 0);
    });
  });
}
