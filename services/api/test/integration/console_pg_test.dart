@Tags(['integration'])
library;

import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The console, against a real database.
///
/// This file is about the one method the pilot was blocked on:
/// [OperatorConsole.materialise]. Until it existed, departures came from
/// hand-written SQL, and every claim about it is a claim about a transaction
/// or about a calendar — neither of which a fake can make.
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
  late String operatorId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    operatorId = PgFixture.operatorId;
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String unique(String prefix) =>
      '$prefix-${++seq}-${DateTime.now().microsecondsSinceEpoch % 100000}';

  Future<({String layoutId, String vehicleId})> fleet({
    SeatLayout? layout,
    String status = 'active',
  }) async {
    final saved = await console.saveLayout(
      operatorId: operatorId,
      name: unique('Coach'),
      layout: layout ?? SeatLayout.busStandard49(),
    );
    final vehicle = await console.saveVehicle(
      operatorId: operatorId,
      registration: unique('REG'),
      layoutId: saved.id,
    );
    if (status != 'active') {
      await console.setVehicleStatus(
        operatorId: operatorId,
        vehicleId: vehicle!.id,
        status: status,
      );
    }
    return (layoutId: saved.id, vehicleId: vehicle!.id);
  }

  Future<String> pattern({
    required String vehicleId,
    Recurrence? recurrence,
    String time = '06:00',
    int fareMinor = 12000,
    DateTime? validFrom,
    DateTime? validUntil,
  }) async {
    final route = await console.saveRoute(
      operatorId: operatorId,
      code: unique('R'),
      originCity: 'BZV',
      destinationCity: 'PNR',
      durationMinutes: 450,
    );
    final saved = await console.savePattern(
      operatorId: operatorId,
      routeId: route!.id,
      recurrence: recurrence ?? Recurrence.daily(),
      departureTime: time,
      fare: Money(fareMinor, Currency.xaf),
      validFrom: validFrom ?? DateTime.utc(2026, 8, 3),
      validUntil: validUntil,
      vehicleId: vehicleId,
    );
    return saved!.id;
  }

  group('fleet templates', () {
    test('one template serves many coaches', () async {
      final layout = await console.saveLayout(
        operatorId: operatorId,
        name: unique('Fleet'),
        layout: SeatLayout.busStandard49(),
      );

      for (var i = 0; i < 3; i++) {
        await console.saveVehicle(
          operatorId: operatorId,
          registration: unique('MANY'),
          layoutId: layout.id,
        );
      }

      // Fourteen coaches is one template and fourteen rows. Drawing the seat
      // map once is the difference between a twenty-minute setup and a
      // two-hour one (`06-fleet-and-routes.md` §1).
      final listed = (await console.layouts(
        operatorId,
      )).firstWhere((l) => l.id == layout.id);
      expect(listed.vehicleCount, 3);
      expect(listed.capacity, SeatLayout.busStandard49().capacity);
    });

    test('saving a template again versions it rather than editing', () async {
      final name = unique('Versioned');
      final first = await console.saveLayout(
        operatorId: operatorId,
        name: name,
        layout: SeatLayout.busStandard49(),
      );
      final second = await console.saveLayout(
        operatorId: operatorId,
        name: name,
        layout: SeatLayout.busVipFront(),
      );

      // A departure keeps the layout it was sold with, so a template change
      // must never be able to renumber a seat somebody already bought.
      expect(second.version, first.version + 1);
      expect(second.id, isNot(first.id));
    });

    test("a coach cannot point at another operator's template", () async {
      final foreign = await fixture.foreignLayout();
      final vehicle = await console.saveVehicle(
        operatorId: operatorId,
        registration: unique('FOREIGN'),
        layoutId: foreign,
      );
      // Otherwise one operator reads a competitor's capacity and section
      // names straight out of their own seat map.
      expect(vehicle, isNull);
    });

    test(
      'taking a coach off the road names the departures it was on',
      () async {
        final f = await fleet();
        final patternId = await pattern(vehicleId: f.vehicleId);
        await console.materialise(
          operatorId: operatorId,
          patternId: patternId,
          from: DateTime.utc(2027, 3, 1),
          to: DateTime.utc(2027, 3, 3),
        );

        final affected = await console.setVehicleStatus(
          operatorId: operatorId,
          vehicleId: f.vehicleId,
          status: 'maintenance',
        );

        // Never silently: these departures now have no coach, and somebody has
        // to reassign one or declare a disruption before the passengers arrive.
        expect(affected, hasLength(3));
      },
    );
  });

  group('materialising a timetable', () {
    test('creates departures and their seat rows', () async {
      final f = await fleet();
      final patternId = await pattern(vehicleId: f.vehicleId);

      final report = await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 4, 1),
        to: DateTime.utc(2027, 4, 7),
      );

      expect(report.created, 7);
      expect(report.skipped, isEmpty);

      // Seat rows are what holds lock against (ADR-0012). A departure without
      // them is a departure nobody can book.
      final departures = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2027, 4, 1),
      );
      expect(departures, hasLength(1));
      expect(departures.single.capacity, SeatLayout.busStandard49().capacity);
      expect(
        await fixture.seatCount(departures.single.id),
        SeatLayout.busStandard49().capacity,
      );
    });

    test('running it twice creates nothing and says so', () async {
      final f = await fleet();
      final patternId = await pattern(vehicleId: f.vehicleId);
      final from = DateTime.utc(2027, 5, 1);
      final to = DateTime.utc(2027, 5, 3);

      final first = await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: from,
        to: to,
      );
      final second = await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: from,
        to: to,
      );

      // A dispatcher who taps twice must not put two coaches on one road —
      // and must be told nothing happened rather than seeing a silent success
      // that looks identical to the first.
      expect(first.created, 3);
      expect(second.created, 0);
      expect(second.alreadyExisted, 3);
    });

    test('a weekly rule materialises only its own days', () async {
      final f = await fleet();
      final patternId = await pattern(
        vehicleId: f.vehicleId,
        recurrence: Recurrence.weekly({DateTime.monday, DateTime.friday}),
        validFrom: DateTime.utc(2027, 6, 7),
      );

      final report = await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 6, 7),
        to: DateTime.utc(2027, 6, 20),
      );

      // 7, 11, 14, 18 June 2027 — Mondays and Fridays.
      expect(report.created, 4);
    });

    test('the departure lands at the local hour, not the UTC one', () async {
      final f = await fleet();
      final patternId = await pattern(
        vehicleId: f.vehicleId,
        time: '06:00',
        validFrom: DateTime.utc(2027, 7, 1),
      );

      await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 7, 1),
        to: DateTime.utc(2027, 7, 1),
      );

      // "The 06:00 from Brazzaville" is a local fact. Congo is UTC+1, so a
      // correct 06:00 local is 05:00Z — and computing the instant in Dart
      // would need this process to know that, and would be wrong the day it
      // ever changed.
      final board = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2027, 7, 1),
      );
      expect(board.single.departsAt.toUtc().hour, 5);
    });

    test('a pattern with no coach names every date it skipped', () async {
      final route = await console.saveRoute(
        operatorId: operatorId,
        code: unique('NOVEH'),
        originCity: 'BZV',
        destinationCity: 'PNR',
        durationMinutes: 450,
      );
      final saved = await console.savePattern(
        operatorId: operatorId,
        routeId: route!.id,
        recurrence: Recurrence.daily(),
        departureTime: '08:00',
        fare: const Money.xaf(9000),
        validFrom: DateTime.utc(2027, 8, 1),
      );

      final report = await console.materialise(
        operatorId: operatorId,
        patternId: saved!.id,
        from: DateTime.utc(2027, 8, 1),
        to: DateTime.utc(2027, 8, 3),
      );

      // A silently missing Thursday is a coach nobody can book and an
      // operator who thinks they are selling it.
      expect(report.created, 0);
      expect(report.skipped, hasLength(3));
      expect(report.skipped.first.reason, 'no_vehicle_assigned');
    });

    test('a coach in the workshop skips, and says which', () async {
      final f = await fleet(status: 'maintenance');
      final patternId = await pattern(vehicleId: f.vehicleId);

      final report = await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 9, 1),
        to: DateTime.utc(2027, 9, 2),
      );

      expect(report.created, 0);
      expect(report.skipped.first.reason, 'vehicle_maintenance');
    });

    test('the range is clamped to the timetable, not refused', () async {
      final f = await fleet();
      final patternId = await pattern(
        vehicleId: f.vehicleId,
        validFrom: DateTime.utc(2027, 10, 5),
        validUntil: DateTime.utc(2027, 10, 7),
      );

      final report = await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 10, 1),
        to: DateTime.utc(2027, 10, 31),
      );

      // Asking for a month of a timetable that runs three days should give
      // three days, not an error and not a month.
      expect(report.created, 3);
    });

    test('a VIP section is priced by the layout, per seat', () async {
      final f = await fleet(layout: SeatLayout.busVipFront());
      final patternId = await pattern(vehicleId: f.vehicleId, fareMinor: 10000);

      await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 11, 1),
        to: DateTime.utc(2027, 11, 1),
      );

      final board = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2027, 11, 1),
      );
      final fares = await fixture.seatFares(board.single.id);

      // The VIP section carries a 1.5x modifier, so the same code sells a
      // 2+2 coach and a two-class cabin without a special case in the sales
      // path (ADR-0017).
      expect(fares.values.toSet(), {10000, 15000});
    });

    test('a condemned seat is never created, and never sold', () async {
      // A wheel arch under 3C and a seat with no window at 7A. The layout
      // still describes a forty-seat coach; two of them are not for sale.
      final drawn = SeatLayout(
        version: 1,
        mode: TransportMode.bus,
        sections: const [
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 10,
            abreast: '2+2',
          ),
        ],
        features: const [LayoutFeature(LayoutFeatureType.door, row: 5, col: 2)],
        blocked: const {'3C', '7A'},
      );

      final f = await fleet(layout: drawn);
      final patternId = await pattern(vehicleId: f.vehicleId);

      await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2028, 3, 5),
        to: DateTime.utc(2028, 3, 5),
      );

      final board = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2028, 3, 5),
      );

      // Not a shorter coach: thirty-eight seat rows out of forty labels, and
      // the two missing ones are the ones the operator pointed at. A blocked
      // seat with a row is a seat somebody can hold (ADR-0012), which is the
      // failure this asserts against.
      expect(board.single.capacity, 38);
      expect(await fixture.seatCount(board.single.id), 38);
      final labels = (await fixture.seatFares(board.single.id)).keys.toSet();
      expect(labels, isNot(contains('3C')));
      expect(labels, isNot(contains('7A')));
      expect(labels, contains('3D'));

      // The door survives the column it was written to. It is drawn on the
      // traveller's seat map, so a decoder that dropped it would only be
      // noticed by somebody sitting next to a door they were not told about.
      final listed = (await console.layouts(
        operatorId,
      )).firstWhere((l) => l.id == f.layoutId);
      expect(listed.capacity, 38);
    });
  });

  group('the manifest', () {
    test('lists confirmed passengers and nobody else', () async {
      final f = await fleet();
      final patternId = await pattern(vehicleId: f.vehicleId);
      await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2027, 12, 1),
        to: DateTime.utc(2027, 12, 1),
      );

      final board = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2027, 12, 1),
      );
      final departureId = board.single.id;

      final bookings = PostgresBookingStore(
        db,
        issuer: await Ed25519TicketIssuer.development(random: Random(1)),
      );

      final unpaid = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '1A',
        name: 'Unpaid P.',
      );
      final paid = await fixture.reserve(
        db: db,
        bookings: bookings,
        departureId: departureId,
        seatLabel: '1B',
        name: 'Paid P.',
      );

      final station = await fixture.station('BZV', 'Agence');
      await bookings.captureCash(
        bookingId: paid.id,
        operatorId: operatorId,
        stationId: station,
        soldByUserId: null,
        posting: Postings.cashSale(
          operatorId: operatorId,
          stationId: station,
          fare: paid.fare,
          serviceFee: paid.serviceFee,
        ).valueOrNull!,
      );

      final manifest = await console.manifest(
        operatorId: operatorId,
        departureId: departureId,
      );

      // A reservation nobody has paid for is not a passenger. Putting one on
      // a manifest is how a conductor ends up arguing at the roadside with
      // somebody holding a phone.
      expect(manifest!.rows.map((r) => r.passengerName), ['Paid P.']);
      expect(manifest.sold, 1);
      expect(manifest.boarded, 0);
      expect(unpaid.state, 'pending_payment');
    });

    test("another operator's departure is not found", () async {
      final f = await fleet();
      final patternId = await pattern(vehicleId: f.vehicleId);
      await console.materialise(
        operatorId: operatorId,
        patternId: patternId,
        from: DateTime.utc(2028, 1, 5),
        to: DateTime.utc(2028, 1, 5),
      );
      final board = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2028, 1, 5),
      );

      final manifest = await console.manifest(
        operatorId: '22222222-2222-2222-2222-222222222222',
        departureId: board.single.id,
      );
      expect(manifest, isNull);
    });
  });

  test('the board separates held from sold', () async {
    final f = await fleet();
    final patternId = await pattern(vehicleId: f.vehicleId);
    await console.materialise(
      operatorId: operatorId,
      patternId: patternId,
      from: DateTime.utc(2028, 2, 2),
      to: DateTime.utc(2028, 2, 2),
    );

    final board = await console.board(
      operatorId: operatorId,
      localDate: DateTime.utc(2028, 2, 2),
    );

    // A coach that is "48 of 49 sold" and one that is "20 sold, 28 held" are
    // completely different situations twenty minutes before departure.
    expect(board.single.sold, 0);
    expect(board.single.held, 0);
    expect(board.single.available, board.single.capacity);
  });

  group('the road between two cities', () {
    Itinerary road(List<RouteStop> stops, {int duration = 450}) => Itinerary.of(
      stops,
      originCity: 'BZV',
      destinationCity: 'PNR',
      durationMinutes: duration,
    ).valueOrNull!;

    Future<RouteSummary> save(Itinerary? stops, {String? id, String? code}) =>
        console
            .saveRoute(
              operatorId: operatorId,
              code: code ?? unique('RS'),
              originCity: 'BZV',
              destinationCity: 'PNR',
              durationMinutes: 450,
              id: id,
              stops: stops,
            )
            .then((r) => r!);

    test('a road with no stops is a road', () async {
      // Most of them are. Making the ordinary case the awkward one would be
      // a schema nobody uses.
      final saved = await save(null);
      expect(saved.stops, isEmpty);
    });

    test('stops come back in the order the road runs them', () async {
      final saved = await save(
        road(const [
          RouteStop(cityCode: 'DOL', offsetMinutes: 315),
          RouteStop(cityCode: 'OYO', offsetMinutes: 70),
        ]),
      );

      // Sorted by time on the way in, and `sequence` is what the read orders
      // by — so the order the operator described is the order every later
      // query sees, whatever order they typed it in.
      expect(saved.stops.map((s) => s.cityCode), ['OYO', 'DOL']);
      expect(saved.stops.map((s) => s.offsetMinutes), [70, 315]);
    });

    test('the list survives a round trip through the routes read', () async {
      final code = unique('RS');
      await save(
        road(const [RouteStop(cityCode: 'DOL', offsetMinutes: 315)]),
        code: code,
      );

      final read = (await console.routes(
        operatorId,
      )).firstWhere((r) => r.code == code);

      expect(read.stops.single.cityCode, 'DOL');
      expect(read.stops.single.offsetMinutes, 315);
    });

    test('saving replaces the road rather than adding to it', () async {
      // A route form is a whole description of a road. Merging would leave a
      // stop the operator deleted still standing on the timetable.
      final first = await save(
        road(const [
          RouteStop(cityCode: 'DOL', offsetMinutes: 315),
          RouteStop(cityCode: 'OYO', offsetMinutes: 70),
        ]),
      );

      final again = await console.saveRoute(
        operatorId: operatorId,
        code: first.code,
        originCity: 'BZV',
        destinationCity: 'PNR',
        durationMinutes: 450,
        id: first.id,
        stops: road(const [RouteStop(cityCode: 'DOL', offsetMinutes: 300)]),
      );

      expect(again!.stops.map((s) => s.cityCode), ['DOL']);
      expect(again.stops.single.offsetMinutes, 300);
    });

    test('an empty list is how the last stop is removed', () async {
      final first = await save(
        road(const [RouteStop(cityCode: 'DOL', offsetMinutes: 315)]),
      );

      final emptied = await console.saveRoute(
        operatorId: operatorId,
        code: first.code,
        originCity: 'BZV',
        destinationCity: 'PNR',
        durationMinutes: 450,
        id: first.id,
        stops: Itinerary.empty,
      );

      expect(emptied!.stops, isEmpty);
    });

    test('omitting the stops leaves the road alone', () async {
      // A caller that predates stops — the timetable screen saving a
      // duration, say — must not be able to erase a road by not mentioning
      // it.
      final first = await save(
        road(const [RouteStop(cityCode: 'DOL', offsetMinutes: 315)]),
      );

      final untouched = await console.saveRoute(
        operatorId: operatorId,
        code: first.code,
        originCity: 'BZV',
        destinationCity: 'PNR',
        durationMinutes: 460,
      );

      expect(untouched!.stops.single.cityCode, 'DOL');
    });

    test('a piece of the road can be priced, and comes back priced', () async {
      final stops = road(const [
        RouteStop(cityCode: 'DOL', offsetMinutes: 315),
      ]);
      final code = unique('RS');

      final saved = await console.saveRoute(
        operatorId: operatorId,
        code: code,
        originCity: 'BZV',
        destinationCity: 'PNR',
        durationMinutes: 450,
        stops: stops,
        segments: SegmentPricing.of(
          const [(from: 'BZV', to: 'DOL', fare: Money.xaf(6000))],
          itinerary: stops,
          originCity: 'BZV',
          destinationCity: 'PNR',
        ).valueOrNull,
      );

      expect(saved!.segments.prices, hasLength(1));
      // Positions, not city codes: a road that visits the same town twice
      // cannot be described by a pair of names (ADR-0025).
      expect(saved.segments.prices.single.segment, Segment.at(0, 1));
      expect(saved.segments.prices.single.fare, const Money.xaf(6000));

      final read = (await console.routes(
        operatorId,
      )).firstWhere((r) => r.code == code);
      expect(read.segments.fareFor(Segment.at(0, 1)), const Money.xaf(6000));
    });

    test('an empty price list is how a leg comes off sale', () async {
      final stops = road(const [
        RouteStop(cityCode: 'DOL', offsetMinutes: 315),
      ]);
      final code = unique('RS');

      Future<RouteSummary> priced(SegmentPricing? list) => console
          .saveRoute(
            operatorId: operatorId,
            code: code,
            originCity: 'BZV',
            destinationCity: 'PNR',
            durationMinutes: 450,
            stops: stops,
            segments: list,
          )
          .then((r) => r!);

      await priced(
        SegmentPricing.of(
          const [(from: 'BZV', to: 'DOL', fare: Money.xaf(6000))],
          itinerary: stops,
          originCity: 'BZV',
          destinationCity: 'PNR',
        ).valueOrNull,
      );

      // Omitted leaves it alone — a caller saving a duration must not be able
      // to take a road off sale by not mentioning its prices.
      final untouched = await priced(null);
      expect(untouched.segments.prices, hasLength(1));

      // Present and empty is the whole list, which is the withdrawal.
      final withdrawn = await priced(SegmentPricing.empty);
      expect(withdrawn.segments.isEmpty, isTrue);
    });

    test('a stop can name one of this operator’s yards', () async {
      final yard = await fixture.station('DOL', 'Gare de Dolisie');

      final saved = await save(
        road([
          RouteStop(
            cityCode: 'DOL',
            offsetMinutes: 315,
            stationId: yard,
            allowsBoarding: false,
          ),
        ]),
      );

      expect(saved.stops.single.stationId, yard);
      // Resolved by the adapter, in the same query, rather than by a request
      // per stop.
      expect(saved.stopStationNames[yard], 'Gare de Dolisie');
      // The detail every naive model gets wrong: set down only.
      expect(saved.stops.single.allowsBoarding, isFalse);
      expect(saved.stops.single.allowsAlighting, isTrue);
    });

    test('another company cannot read this road', () async {
      final code = unique('RS');
      await save(
        road(const [RouteStop(cityCode: 'DOL', offsetMinutes: 315)]),
        code: code,
      );

      final theirs = await console.routes(await fixture.secondOperator());

      // The stops ride on the route's own tenant policy, so this is the
      // policy answering rather than a WHERE clause.
      expect(theirs.map((r) => r.code), isNot(contains(code)));
    });
  });
}
