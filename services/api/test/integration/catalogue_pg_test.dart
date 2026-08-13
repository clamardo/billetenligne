@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/departure_catalogue.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_departure_catalogue.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_api/src/application/ports/seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The catalogue, against real SQL.
///
/// Three things here cannot be tested anywhere else:
///
///   * **The local-day question.** "Departures on the 15th" is answered by
///     `AT TIME ZONE`, and getting it wrong puts the 06:00 coach on the wrong
///     day for everyone. A Dart fake comparing UTC dates would agree with
///     itself and be wrong in Brazzaville.
///   * **A public connection can read the catalogue at all.** Browsing runs
///     with no tenant and no account. Under migration 0004 alone it saw an
///     empty database.
///   * **Availability reflects live holds**, including that a lapsed one reads
///     as available without a sweeper having run.
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresDepartureCatalogue catalogue;
  late PostgresSeatInventory inventory;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 6);
    catalogue = PostgresDepartureCatalogue(
      db,
      timeZone: Market.current.timeZone,
    );
    inventory = PostgresSeatInventory(db);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  DepartureQuery query({
    required DateTime date,
    String from = 'BZV',
    String to = 'PNR',
    String? operatorId,
  }) => DepartureQuery(
    originCity: from,
    destinationCity: to,
    localDate: date,
    operatorId: operatorId,
  );

  group('browsing without an account', () {
    test('an anonymous connection can see a departure at all', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B', '1C'],
        fromNow: const Duration(hours: 6),
      );

      final results = await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 6))),
      );

      // Under migration 0004 alone this list was empty: a traveller belongs to
      // no operator, so every tenant policy said no. ADR-0023 is what makes
      // this line pass.
      expect(results.map((d) => d.id), contains(departureId));
    });

    test('carries what a search row actually renders', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 7),
        fareMinor: 15000,
      );

      final row = (await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 7))),
      )).firstWhere((d) => d.id == departureId);

      expect(row.operatorName, 'Ocean du Nord');
      expect(row.fare.minor, 15000);
      expect(row.fare.currency.code, 'XAF');
      expect(row.originCity, 'BZV');
      expect(row.destinationCity, 'PNR');
      expect(row.seatsAvailable, 2);
      expect(row.capacity, 2);
    });

    test('the on-time figure travels with the row, or does not', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 9),
      );

      Future<int?> rateOnTheRow() async => (await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 9))),
      )).firstWhere((d) => d.id == departureId).onTimeRate;

      // Nothing computed yet: the column is null, and a null must arrive as a
      // null rather than as a zero — an operator nobody has data about must
      // not read as the worst one on the screen.
      await fixture.setOnTimeRate(null);
      expect(await rateOnTheRow(), isNull);

      // And once the nightly pass has written one, every search carries it
      // without a join: it is a column read (0027).
      await fixture.setOnTimeRate(92);
      expect(await rateOnTheRow(), 92);
    });

    test('the yard travels with the row, and the directions with it', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 11),
      );

      Future<DepartureRow> row() async => (await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 11))),
      )).firstWhere((d) => d.id == departureId);

      // No terminal named: null, not an invented "Gare routière". A row that
      // guessed would send somebody to a gate nobody at that company knows.
      expect((await row()).originStation, isNull);

      final mikalou = await fixture.station(
        'BZV',
        'Gare de Mikalou',
        boardingNotes: 'Entrée par la rue derrière la station Total',
      );
      final loandjili = await fixture.station('PNR', 'Gare de Loandjili');
      await fixture.setStations(
        departureId,
        origin: mikalou,
        destination: loandjili,
      );

      final named = await row();
      expect(named.originStation?.name, 'Gare de Mikalou');
      expect(
        named.originStation?.boardingNotes,
        'Entrée par la rue derrière la station Total',
      );
      expect(named.destinationStation?.name, 'Gare de Loandjili');
    });

    test('a rival cannot be named as the yard we leave from', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 12),
      );
      final theirs = await fixture.station(
        'BZV',
        'Gare concurrente',
        onOperator: await fixture.secondOperator(),
      );

      // The composite foreign key, not a WHERE clause somebody can forget:
      // a mistyped id cannot put a rival's address on our ticket.
      await expectLater(
        fixture.setStations(departureId, origin: theirs),
        throwsA(anything),
      );
    });
  });

  group('the local-day question', () {
    test('a departure is found on its local calendar day', () async {
      // 03:00 Brazzaville is 02:00 UTC — the same day either way, so this one
      // is the control.
      final departureId = await fixture.departureAtLocalTime(
        seatLabels: ['1A'],
        daysAhead: 3,
        localHour: 3,
      );

      final localDate = await fixture.localDateAheadOfToday(3);
      final results = await catalogue.search(query(date: localDate));

      expect(results.map((d) => d.id), contains(departureId));
    });

    test('and not on the day before or after', () async {
      final departureId = await fixture.departureAtLocalTime(
        seatLabels: ['1A'],
        daysAhead: 4,
        localHour: 6,
      );

      final before = await catalogue.search(
        query(date: await fixture.localDateAheadOfToday(3)),
      );
      final after = await catalogue.search(
        query(date: await fixture.localDateAheadOfToday(5)),
      );

      expect(before.map((d) => d.id), isNot(contains(departureId)));
      expect(after.map((d) => d.id), isNot(contains(departureId)));
    });

    test('a late-evening departure stays on its own day', () async {
      // 23:00 in Brazzaville is 22:00 UTC. Both land on the same date here,
      // but the moment a market east of UTC+1 exists this is the case that
      // breaks first — which is why the timezone is a parameter and not a
      // literal in the SQL.
      final departureId = await fixture.departureAtLocalTime(
        seatLabels: ['1A'],
        daysAhead: 6,
        localHour: 23,
      );

      final results = await catalogue.search(
        query(date: await fixture.localDateAheadOfToday(6)),
      );

      expect(results.map((d) => d.id), contains(departureId));
    });
  });

  group('what a search must not return', () {
    test('a cancelled departure', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 9),
        status: 'cancelled',
      );

      final results = await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 9))),
      );

      expect(results.map((d) => d.id), isNot(contains(departureId)));
    });

    test('one that has already left', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: -2),
      );

      final results = await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: -2))),
      );

      // The traveller searching at 06:05 for the 06:00 needs the 09:00, not a
      // row they cannot buy.
      expect(results.map((d) => d.id), isNot(contains(departureId)));
    });

    test('one whose sales have closed', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 2),
        salesCloseIn: const Duration(seconds: -1),
      );

      final results = await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 2))),
      );

      expect(results.map((d) => d.id), isNot(contains(departureId)));
    });
  });

  group('availability is live', () {
    test('a hold reduces the count', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B', '1C', '1D'],
        fromNow: const Duration(hours: 11),
      );
      final userId = await fixture.traveller('cat-hold');
      final date = await fixture.localDateIn(const Duration(hours: 11));

      final before = (await catalogue.search(
        query(date: date),
      )).firstWhere((d) => d.id == departureId);
      expect(before.seatsAvailable, 4);

      await inventory.claim(
        fixture.claimFor(
          departureId: departureId,
          userId: userId,
          seatLabels: ['1A', '1B'],
          key: 'cat-hold-key',
        ),
      );

      final after = (await catalogue.search(
        query(date: date),
      )).firstWhere((d) => d.id == departureId);
      expect(after.seatsAvailable, 2);
    });

    test('a lapsed hold counts as available, with no sweeper', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 13),
      );
      final userId = await fixture.traveller('cat-lapse');
      final date = await fixture.localDateIn(const Duration(hours: 13));

      final claimed =
          await inventory.claim(
                fixture.claimFor(
                  departureId: departureId,
                  userId: userId,
                  seatLabels: ['1A'],
                  key: 'cat-lapse-key',
                ),
              )
              as SeatsClaimed;
      await fixture.expireHold(claimed.holdId);

      final row = (await catalogue.search(
        query(date: date),
      )).firstWhere((d) => d.id == departureId);

      // Nothing ran in between. A stalled worker must not be able to show a
      // coach as full when it is empty.
      expect(row.seatsAvailable, 2);
    });
  });

  group('the seat map', () {
    test('carries every seat with its own price', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B', '2A'],
        fromNow: const Duration(hours: 15),
        fareMinor: 9000,
      );

      final map = await catalogue.seatMap(departureId);

      expect(map!.seats, hasLength(3));
      expect(map.seats.every((s) => s.fare!.minor == 9000), isTrue);
      expect(map.availableCount, 3);
    });

    test('shows a held seat as held', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A', '1B'],
        fromNow: const Duration(hours: 16),
      );
      final userId = await fixture.traveller('cat-map');

      await inventory.claim(
        fixture.claimFor(
          departureId: departureId,
          userId: userId,
          seatLabels: ['1A'],
          key: 'cat-map-key',
        ),
      );

      final map = await catalogue.seatMap(departureId);

      expect(
        map!.seats.firstWhere((s) => s.label == '1A').status,
        SeatStatusDto.held,
      );
      expect(map.availableCount, 1);
    });

    test('a cancelled departure still has a seat map', () async {
      final departureId = await fixture.departure(
        seatLabels: ['1A'],
        fromNow: const Duration(hours: 17),
        status: 'cancelled',
      );

      // It is gone from search, but somebody holding a ticket for it needs to
      // see what happened to their coach.
      expect(await catalogue.seatMap(departureId), isNotNull);
    });

    test('an unknown departure is null, not an empty map', () async {
      expect(
        await catalogue.seatMap('00000000-0000-0000-0000-0000000000ff'),
        isNull,
      );
    });
  });

  group('one page at a time', () {
    /// Four coaches on the same road, minutes apart, on a day of their own —
    /// so the paging assertions count these and not whatever every other
    /// suite in this run happened to schedule.
    Future<({DateTime date, List<String> ids})> aDayOfCoaches() async {
      final offset = const Duration(days: 40);
      final ids = <String>[];
      for (var i = 0; i < 4; i++) {
        ids.add(
          await fixture.departure(
            seatLabels: const ['1A'],
            fromNow: offset + Duration(minutes: i),
          ),
        );
      }
      return (date: await fixture.localDateIn(offset), ids: ids);
    }

    test('a page is the size it was asked for, and no more', () async {
      final day = await aDayOfCoaches();

      final rows = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: day.date,
          limit: 2,
        ),
      );

      expect(rows, hasLength(2));
    });

    test('the cursor resumes exactly after the row it names', () async {
      final day = await aDayOfCoaches();

      final first = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: day.date,
          limit: 2,
        ),
      );

      final second = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: day.date,
          limit: 2,
          after: SearchCursor(
            departsAt: first.last.departsAt,
            id: first.last.id,
          ),
        ),
      );

      // Strictly after: the row the cursor names must not come back, which is
      // the difference between `>` and `>=` and one duplicated coach per page.
      expect(second.map((d) => d.id), isNot(contains(first.last.id)));
      expect(
        first
            .map((d) => d.id)
            .toSet()
            .intersection(second.map((d) => d.id).toSet()),
        isEmpty,
      );
    });

    test('two coaches at the same minute are both reachable', () async {
      // The tie the id breaks. Two companies scheduling the 06:00 on the same
      // road is the ordinary case here, and a cursor keyed on the instant
      // alone would swallow one of them for good.
      final offset = const Duration(days: 41);
      final twins = [
        await fixture.departure(seatLabels: const ['1A'], fromNow: offset),
        await fixture.departure(seatLabels: const ['1A'], fromNow: offset),
      ];
      // Truly the same instant, not merely the same minute: `now() +
      // interval` gives each row its own microsecond, and a tie that is not
      // a tie proves nothing about the tie-break.
      await fixture.sameInstant(departure: twins.first, other: twins.last);
      final date = await fixture.localDateIn(offset);

      final first = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: date,
          limit: 1,
        ),
      );
      final second = await catalogue.search(
        DepartureQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          localDate: date,
          limit: 1,
          after: SearchCursor(
            departsAt: first.single.departsAt,
            id: first.single.id,
          ),
        ),
      );

      expect(first.single.departsAt, second.single.departsAt);
      expect({first.single.id, second.single.id}, twins.toSet());
    });

    test('paging the whole day sees every coach once', () async {
      final day = await aDayOfCoaches();
      final seen = <String>[];

      SearchCursor? after;
      for (var guard = 0; guard < 10; guard++) {
        final rows = await catalogue.search(
          DepartureQuery(
            originCity: 'BZV',
            destinationCity: 'PNR',
            localDate: day.date,
            limit: 3,
            after: after,
          ),
        );
        if (rows.isEmpty) break;
        seen.addAll(rows.map((d) => d.id));
        after = SearchCursor(departsAt: rows.last.departsAt, id: rows.last.id);
      }

      expect(seen.toSet(), containsAll(day.ids));
      expect(seen.length, seen.toSet().length, reason: 'no coach twice');
    });
  });

  group('the towns on the road', () {
    test('a direct coach names none', () async {
      // Most roads in this market are two towns and the tarmac between them.
      // Empty here is a road with no stops, not a road we know nothing about.
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 9),
      );

      final row = (await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 9))),
      )).firstWhere((d) => d.id == departureId);

      expect(row.via, isEmpty);
    });

    test('a coach with stops names them, in the order it runs them', () async {
      final road = await fixture.route(code: 'VIA-BZV-PNR', destination: 'PNR');
      await fixture.stopsOn(road, const [
        (city: 'OYO', offsetMinutes: 70),
        (city: 'DOL', offsetMinutes: 315),
      ]);

      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 10),
        onRoute: road,
      );

      final row = (await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 10))),
      )).firstWhere((d) => d.id == departureId);

      expect(row.via, ['OYO', 'DOL']);
    });

    test('naming the towns does not disturb the seat count', () async {
      // The stops are a correlated subquery rather than a join, and this is
      // the reason: a join to a one-to-many multiplies the rows the same
      // statement is counting seats over, so two stops would have made every
      // coach look three times as full.
      final road = await fixture.route(code: 'VIA-COUNT', destination: 'PNR');
      await fixture.stopsOn(road, const [
        (city: 'OYO', offsetMinutes: 70),
        (city: 'DOL', offsetMinutes: 315),
      ]);

      final departureId = await fixture.departure(
        seatLabels: const ['1A', '1B', '1C'],
        fromNow: const Duration(hours: 11),
        onRoute: road,
      );

      final row = (await catalogue.search(
        query(date: await fixture.localDateIn(const Duration(hours: 11))),
      )).firstWhere((d) => d.id == departureId);

      expect(row.seatsAvailable, 3);
      expect(row.capacity, 3);
    });
  });

  // ── A piece of the road ────────────────────────────────────────────────────
  //
  // The search a traveller standing in Dolisie makes. Nothing on this road
  // starts or ends there, so before ADR-0025 it returned an empty screen while
  // three coaches a day went past the door — which is the trade every operator
  // on the corridor already makes at the roadside, out of a notebook.
  //
  // Every row here is a leg the operator has *priced*. There is deliberately
  // no pro-rata fallback: an unpriced pair is not on sale, which is what makes
  // the whole feature arrive switched off rather than switched on wrong.
  group('a leg somebody priced', () {
    /// A road nobody else in this suite searches, so the rows below cannot
    /// wander into another file's assertions. The integration database is
    /// shared and absolute counts on a shared road are how a suite passes for
    /// the wrong reason.
    Future<String> corridor(
      String code, {
      Set<String> setDownOnly = const {},
    }) async {
      final road = await fixture.route(
        code: code,
        origin: 'BZV',
        destination: 'OYO',
      );
      await fixture.stopsOn(road, const [
        (city: 'DOL', offsetMinutes: 180),
      ], setDownOnly: setDownOnly);
      return road;
    }

    test('is found between two towns the route does not end at', () async {
      final road = await corridor('LEG-FOUND');
      await fixture.priceSegment(
        road,
        fromPosition: 1,
        toPosition: 2,
        fareMinor: 7000,
      );
      final departureId = await fixture.departure(
        seatLabels: const ['1A', '1B'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );

      final results = await catalogue.search(
        query(
          from: 'DOL',
          to: 'OYO',
          date: await fixture.localDateIn(const Duration(hours: 15)),
        ),
      );
      final row = results.firstWhere((d) => d.id == departureId);

      // An ordinary departure between the two towns asked for — which is the
      // whole design of the wire here: no new shape, no new screen, and a
      // client that has never heard of segments renders it correctly.
      expect(row.originCity, 'DOL');
      expect(row.destinationCity, 'OYO');
      // The operator's price, never a fraction of the through fare invented
      // by us. 7 000, not some share of 12 000.
      expect(row.fare, const Money.xaf(7000));
      // Boarding three hours after the coach left Brazzaville.
      expect(
        row.departsAt.difference(await fixture.departsAt(departureId)),
        const Duration(hours: 3),
      );
      // And no town on the row that this passenger will never see.
      expect(row.via, isEmpty);
    });

    test('an unpriced leg is not on sale', () async {
      final road = await corridor('LEG-UNPRICED');
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );

      final results = await catalogue.search(
        query(
          from: 'DOL',
          to: 'OYO',
          date: await fixture.localDateIn(const Duration(hours: 15)),
        ),
      );

      expect(results.map((d) => d.id), isNot(contains(departureId)));
    });

    test('a withdrawn price takes the leg off sale', () async {
      final road = await corridor('LEG-WITHDRAWN');
      await fixture.priceSegment(
        road,
        fromPosition: 1,
        toPosition: 2,
        active: false,
      );
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );

      final results = await catalogue.search(
        query(
          from: 'DOL',
          to: 'OYO',
          date: await fixture.localDateIn(const Duration(hours: 15)),
        ),
      );

      expect(results.map((d) => d.id), isNot(contains(departureId)));
    });

    test('a set-down-only stop cannot start one', () async {
      // Priced anyway, directly through the seed connection: the console
      // refuses to write this, and the search must refuse to act on it if it
      // ever exists. A coach that only puts people down at Dolisie must not
      // sell a ticket from Dolisie.
      final road = await corridor('LEG-SETDOWN', setDownOnly: {'DOL'});
      await fixture.priceSegment(road, fromPosition: 1, toPosition: 2);
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );

      final results = await catalogue.search(
        query(
          from: 'DOL',
          to: 'OYO',
          date: await fixture.localDateIn(const Duration(hours: 15)),
        ),
      );

      expect(results.map((d) => d.id), isNot(contains(departureId)));
    });

    test('the seat map answers for the leg, at the leg'
        's price', () async {
      final road = await corridor('LEG-MAP');
      await fixture.priceSegment(
        road,
        fromPosition: 1,
        toPosition: 2,
        fareMinor: 5500,
      );
      final departureId = await fixture.departure(
        seatLabels: const ['1A', '1B'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );
      await fixture.occupyLeg(departureId, '1A', from: 0, to: 1);

      final leg = await catalogue.seatMap(
        departureId,
        fromCity: 'DOL',
        toCity: 'OYO',
      );

      // 1A is sold as far as Dolisie and empty afterwards, which is exactly
      // the seat somebody boarding at Dolisie should be offered.
      expect(
        leg!.seats.firstWhere((s) => s.label == '1A').status,
        SeatStatusDto.available,
      );
      // The operator's price for the leg, flat across the coach. Not a
      // fraction of the through fare, and not the seat's own 12 000.
      expect(leg.seats.first.fare, const Money.xaf(5500));

      // The same coach, asked about as a whole journey: the first half is
      // taken, so the seat is not for sale.
      final whole = await catalogue.seatMap(departureId);
      expect(
        whole!.seats.firstWhere((s) => s.label == '1A').status,
        SeatStatusDto.held,
      );
      expect(whole.seats.first.fare, const Money.xaf(12000));
    });

    test('a pair nobody priced has no seat map at all', () async {
      final road = await corridor('LEG-MAP-NONE');
      final departureId = await fixture.departure(
        seatLabels: const ['1A'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );

      // Not an empty coach and not the whole road: a leg that is not on sale
      // has nothing to draw, and a coach with every seat greyed out would
      // read as full rather than as unsold.
      expect(
        await catalogue.seatMap(departureId, fromCity: 'DOL', toCity: 'OYO'),
        isNull,
      );
      // The road's own two ends are the ordinary whole-journey request, which
      // is what lets a client send back whatever pair it searched with.
      expect(
        await catalogue.seatMap(departureId, fromCity: 'BZV', toCity: 'OYO'),
        isNotNull,
      );
    });

    test('a seat sold on the first half is free on the second', () async {
      final road = await corridor('LEG-HALF');
      await fixture.priceSegment(road, fromPosition: 0, toPosition: 1);
      await fixture.priceSegment(road, fromPosition: 1, toPosition: 2);
      final departureId = await fixture.departure(
        seatLabels: const ['1A', '1B'],
        fromNow: const Duration(hours: 12),
        onRoute: road,
      );

      // Somebody takes 1A as far as Dolisie, and only that far.
      await fixture.occupyLeg(departureId, '1A', from: 0, to: 1);

      final boarding = await catalogue.search(
        query(
          from: 'DOL',
          to: 'OYO',
          date: await fixture.localDateIn(const Duration(hours: 15)),
        ),
      );
      final leaving = await catalogue.search(
        query(
          from: 'BZV',
          to: 'DOL',
          date: await fixture.localDateIn(const Duration(hours: 12)),
        ),
      );

      // Both seats are still for sale to somebody boarding at Dolisie: the
      // one that was sold is empty from there on, which is the entire point
      // of a range and is invisible to anything that asks `seats.state`.
      expect(boarding.firstWhere((d) => d.id == departureId).seatsAvailable, 2);
      // And one of them has gone for the leg that was actually sold.
      expect(leaving.firstWhere((d) => d.id == departureId).seatsAvailable, 1);
    });
  });
}
