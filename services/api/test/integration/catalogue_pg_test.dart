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
}
