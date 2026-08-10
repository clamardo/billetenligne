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
}
