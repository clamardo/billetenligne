import 'package:bel_api/src/application/ports/seat_inventory.dart';
import 'package:bel_api/src/application/search_departures.dart';
import 'package:bel_api/src/infrastructure/memory/memory_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 9, 6);
  final clock = FixedClock(now);
  final today = DateTime.utc(2026, 8, 9);

  (SearchDepartures, MemorySeatInventory) build() {
    final inventory = MemorySeatInventory(
      clock: clock,
      departures: [
        MemoryDeparture.coach(
          id: 'dep-morning',
          operatorId: 'op-odn',
          operatorName: 'Ocean du Nord',
          departsAt: now.add(const Duration(hours: 3)),
        ),
        MemoryDeparture.coach(
          id: 'dep-evening',
          operatorId: 'op-tbv',
          operatorName: 'Trans Bony Voyages',
          departsAt: now.add(const Duration(hours: 12)),
        ),
        // Already left. A traveller searching at 06:00 for the 05:00 needs
        // the next one, not a row they cannot buy.
        MemoryDeparture.coach(
          id: 'dep-departed',
          operatorId: 'op-odn',
          departsAt: now.subtract(const Duration(hours: 1)),
        ),
        MemoryDeparture.coach(
          id: 'dep-cancelled',
          operatorId: 'op-odn',
          departsAt: now.add(const Duration(hours: 5)),
          status: 'cancelled',
        ),
        MemoryDeparture.coach(
          id: 'dep-other-route',
          operatorId: 'op-odn',
          departsAt: now.add(const Duration(hours: 4)),
          originCity: 'BZV',
          destinationCity: 'OWE',
        ),
      ],
    );

    return (
      SearchDepartures(
        catalogue: MemoryDepartureCatalogue(inventory, clock: clock),
      ),
      inventory,
    );
  }

  SearchDeparturesQuery query({
    String from = 'BZV',
    String to = 'PNR',
    int passengers = 1,
    DateTime? date,
    String? operatorId,
  }) => SearchDeparturesQuery(
    originCity: from,
    destinationCity: to,
    date: date ?? today,
    passengers: passengers,
    operatorId: operatorId,
  );

  group('what comes back', () {
    test('sellable departures, soonest first', () async {
      final (search, _) = build();

      final results = (await search(query(), now: now)).valueOrNull!;

      expect(results.departures.map((d) => d.id), [
        'dep-morning',
        'dep-evening',
      ]);
    });

    test('adds the service fee once, from the market', () async {
      final (search, _) = build();

      final first = (await search(
        query(),
        now: now,
      )).valueOrNull!.departures.first;

      // The database has no business knowing what Congo charges. Adding a
      // second country must not mean editing SQL.
      expect(first.fare, const Money.xaf(12000));
      expect(first.serviceFee, Market.current.serviceFee);
      expect(first.total, const Money.xaf(12300));
    });

    test('a departure that has left is not a result', () async {
      final (search, _) = build();

      final results = (await search(query(), now: now)).valueOrNull!;

      expect(
        results.departures.map((d) => d.id),
        isNot(contains('dep-departed')),
      );
    });

    test('a cancelled departure is not a result', () async {
      final (search, _) = build();

      final results = (await search(query(), now: now)).valueOrNull!;

      expect(
        results.departures.map((d) => d.id),
        isNot(contains('dep-cancelled')),
      );
    });

    test('another route is not a result', () async {
      final (search, _) = build();

      final results = (await search(query(), now: now)).valueOrNull!;

      expect(
        results.departures.map((d) => d.id),
        isNot(contains('dep-other-route')),
      );
    });

    test('filters by operator when asked', () async {
      final (search, _) = build();

      final results = (await search(
        query(operatorId: 'op-tbv'),
        now: now,
      )).valueOrNull!;

      expect(results.departures.map((d) => d.id), ['dep-evening']);
    });
  });

  group('availability', () {
    test('drops as seats are held', () async {
      final (search, inventory) = build();

      final before = (await search(
        query(),
        now: now,
      )).valueOrNull!.departures.first;

      await inventory.claim(
        SeatClaimFixture.forSeats(['1A', '1B'], departureId: 'dep-morning'),
      );

      final after = (await search(
        query(),
        now: now,
      )).valueOrNull!.departures.first;

      expect(after.seatsAvailable, before.seatsAvailable - 2);
    });

    test('a sold-out departure is returned, not hidden', () async {
      final inventory = MemorySeatInventory(
        clock: clock,
        departures: [
          MemoryDeparture(
            id: 'dep-tiny',
            operatorId: 'op-odn',
            departsAt: now.add(const Duration(hours: 2)),
            seatLabels: const ['1A'],
          ),
        ],
      );
      final search = SearchDepartures(
        catalogue: MemoryDepartureCatalogue(inventory, clock: clock),
      );

      await inventory.claim(
        SeatClaimFixture.forSeats(['1A'], departureId: 'dep-tiny'),
      );

      final results = (await search(query(), now: now)).valueOrNull!;

      // Seeing "complet" on the 06:00 is how a traveller learns to book
      // earlier. Hiding it makes the service look empty instead.
      expect(results.departures, hasLength(1));
      expect(results.departures.first.isSoldOut, isTrue);
    });
  });

  group('refusals', () {
    test('the same city twice is a stated error, not an empty list', () async {
      final (search, _) = build();

      final result = await search(
        query(from: 'BZV', to: 'BZV'),
        now: now,
      );

      expect(result.failureOrNull, isA<SameOriginAndDestination>());
    });

    test('an absurd party size is refused', () async {
      final (search, _) = build();

      final result = await search(query(passengers: 40), now: now);

      expect(result.failureOrNull, isA<UnreasonablePassengerCount>());
    });

    test('a date years out is a typo, not a plan', () async {
      final (search, _) = build();

      final result = await search(
        query(date: DateTime.utc(2030, 1, 1)),
        now: now,
      );

      // Distinguished from "no results" on purpose: those two look identical
      // to a traveller who fat-fingered the year.
      expect(result.failureOrNull, isA<DateOutOfRange>());
    });
  });

  group('the seat map', () {
    test('reflects a hold immediately', () async {
      final (_, inventory) = build();
      final catalogue = MemoryDepartureCatalogue(inventory, clock: clock);

      await inventory.claim(
        SeatClaimFixture.forSeats(['2A'], departureId: 'dep-morning'),
      );

      final map = await catalogue.seatMap('dep-morning');
      final seat = map!.seats.firstWhere((s) => s.label == '2A');

      expect(seat.status, SeatStatusDto.held);
      expect(seat.isSelectable, isFalse);
    });

    test('prices every seat, so a VIP row cannot surprise anyone', () async {
      final (_, inventory) = build();
      final catalogue = MemoryDepartureCatalogue(inventory, clock: clock);

      final map = await catalogue.seatMap('dep-morning');

      expect(map!.seats.every((s) => s.fare != null), isTrue);
    });

    test('an unknown departure is null, not an empty map', () async {
      final (_, inventory) = build();
      final catalogue = MemoryDepartureCatalogue(inventory, clock: clock);

      // An empty seat map and a departure that does not exist mean very
      // different things to a client deciding what to render.
      expect(await catalogue.seatMap('nope'), isNull);
    });
  });

  group('one page at a time', () {
    /// Eight coaches on the hour, so the page boundaries land somewhere
    /// checkable rather than on the edge of the fixture.
    (SearchDepartures, MemorySeatInventory) manyCoaches({
      int size = 3,
      Set<String> without = const {},
    }) {
      final inventory = MemorySeatInventory(
        clock: clock,
        departures: [
          for (var i = 0; i < 8; i++)
            if (!without.contains('dep-${i.toString().padLeft(2, '0')}'))
              MemoryDeparture.coach(
                id: 'dep-${i.toString().padLeft(2, '0')}',
                operatorId: 'op-odn',
                departsAt: now.add(Duration(hours: 2 + i)),
              ),
        ],
      );
      return (
        SearchDepartures(
          catalogue: MemoryDepartureCatalogue(inventory, clock: clock),
          pageSize: size,
        ),
        inventory,
      );
    }

    test('answers a page, and says there is more', () async {
      final (search, _) = manyCoaches();

      final page = (await search(query(), now: now)).valueOrNull!;

      expect(page.departures.map((d) => d.id), ['dep-00', 'dep-01', 'dep-02']);
      // Told, not inferred. A full page is not evidence of another one.
      expect(page.nextCursor, isNotNull);
    });

    test('the next page starts exactly where the last one stopped', () async {
      final (search, _) = manyCoaches();

      final first = (await search(query(), now: now)).valueOrNull!;
      final second = (await search(
        query().nextPage(first.nextCursor!),
        now: now,
      )).valueOrNull!;

      expect(second.departures.map((d) => d.id), [
        'dep-03',
        'dep-04',
        'dep-05',
      ]);
      // No overlap and no gap — the two things an offset gets wrong the
      // moment the list underneath moves.
      expect(
        {
          ...first.departures.map((d) => d.id),
        }.intersection({...second.departures.map((d) => d.id)}),
        isEmpty,
      );
    });

    test('the last page says so by saying nothing', () async {
      final (search, _) = manyCoaches();

      var page = (await search(query(), now: now)).valueOrNull!;
      final seen = <String>[...page.departures.map((d) => d.id)];
      var guard = 0;
      while (page.nextCursor != null && guard++ < 10) {
        page = (await search(
          query().nextPage(page.nextCursor!),
          now: now,
        )).valueOrNull!;
        seen.addAll(page.departures.map((d) => d.id));
      }

      expect(page.nextCursor, isNull);
      expect(seen, hasLength(8));
      expect(seen.toSet(), hasLength(8), reason: 'no coach twice');
    });

    test('a coach withdrawn mid-scroll costs no other coach its row', () async {
      final (first_search, _) = manyCoaches();
      final first = (await first_search(query(), now: now)).valueOrNull!;

      // dep-01 goes off sale while the traveller is reading page one — the
      // row an OFFSET would have counted. A keyset asks for everything after
      // dep-02 instead, so nothing above it can shift the answer.
      final (later, _) = manyCoaches(without: {'dep-01'});
      final second = (await later(
        query().nextPage(first.nextCursor!),
        now: now,
      )).valueOrNull!;

      expect(second.departures.first.id, 'dep-03');
    });

    test('a page size is clamped, not obeyed', () async {
      final (search, _) = manyCoaches();

      // "Give me ten thousand rows" is a slow query anybody can ask for by
      // typing it into a URL.
      final page = (await search(
        SearchDeparturesQuery(
          originCity: 'BZV',
          destinationCity: 'PNR',
          date: today,
          limit: 100000,
        ),
        now: now,
      )).valueOrNull!;

      expect(page.departures, hasLength(8));
      expect(page.nextCursor, isNull);
    });

    test('a cursor nobody minted is a refusal, not page one', () async {
      final (search, _) = manyCoaches();

      final result = await search(query().nextPage('nonsense'), now: now);

      // Silently starting again is how a client scrolls forever reading the
      // same three coaches.
      expect(result.isOk, isFalse);
      expect((result as Err).failure, isA<UnreadableCursor>());
    });
  });
}

/// Small helper so these tests read as searches rather than as claims.
abstract final class SeatClaimFixture {
  static SeatClaim forSeats(
    List<String> labels, {
    required String departureId,
    String userId = 'u-someone',
  }) => SeatClaim(
    departureId: departureId,
    seatLabels: labels,
    userId: userId,
    ttl: const Duration(minutes: 15),
    idempotencyKey: 'fixture-${labels.join()}-$departureId',
  );
}
