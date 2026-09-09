@Tags(['integration'])
library;

import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// J4 — a departure has a state, and something writes it.
///
/// The transition table itself is proved pure in `bel_platform`. What is
/// proved here is everything a pure table cannot reach: that the write is
/// one-way under a real `WHERE`, that closing a coach lets go of the
/// checkouts still in flight on it rather than selling them, that a scan
/// still validates afterwards, and that the first scan is what puts a coach
/// into `boarding` — including when the handset that made it has been out of
/// signal for three hours.
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
  late PostgresBookingStore bookings;
  late HoldSeats hold;
  late ReserveBooking reserve;
  late String driver;
  late String stranger;
  late String stationId;
  late String vendorId;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl, maxConnections: 8);
    console = PostgresOperatorConsole(db, timeZone: PgFixture.timeZone);
    bookings = PostgresBookingStore(
      db,
      issuer: await Ed25519TicketIssuer.development(),
    );
    hold = HoldSeats(inventory: PostgresSeatInventory(db));
    reserve = ReserveBooking(bookings: bookings);

    driver = await fixture.staffMember(roles: const ['driver'], suffix: '2001');
    // Staff, holds the role, and is on nobody's coach. The capability alone
    // would let this person close every departure in the company.
    stranger = await fixture.staffMember(
      roles: const ['driver'],
      suffix: '2002',
    );
    stationId = await fixture.station('BZV', 'Agence Lifecycle');
    vendorId = await fixture.traveller('lifecycle-vendor', name: 'Vendeur');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String key() => 'lifecycle-${++seq}-${DateTime.now().microsecondsSinceEpoch}';

  /// A coach with [driver] rostered on it, which is the normal case.
  Future<String> crewedDeparture({
    List<String> seatLabels = const ['1A'],
    Duration fromNow = const Duration(hours: 8),
  }) async {
    final departureId = await fixture.departure(
      seatLabels: seatLabels,
      fromNow: fromNow,
    );
    await console.assignCrew(
      operatorId: PgFixture.operatorId,
      departureId: departureId,
      staffUserId: driver,
      role: CrewRole.driver,
      actorUserId: driver,
    );
    return departureId;
  }

  /// A confirmed booking with tickets on it.
  ///
  /// `reserve` alone stops at `pending_payment`, which has no tickets — and a
  /// manifest is made of tickets, so a scan against an unpaid booking finds
  /// nothing. Every claim in this file about boarding needs somebody who
  /// actually paid.
  Future<({String ref, String id})> paid(
    String departureId, {
    String seatLabel = '1A',
    String name = 'Aline M.',
  }) async {
    final booking = await fixture.reserve(
      db: db,
      bookings: bookings,
      departureId: departureId,
      seatLabel: seatLabel,
      name: name,
    );
    final captured = await bookings.captureCash(
      bookingId: booking.id,
      operatorId: PgFixture.operatorId,
      stationId: stationId,
      soldByUserId: vendorId,
      posting: Postings.cashSale(
        operatorId: PgFixture.operatorId,
        stationId: stationId,
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!,
    );
    return (ref: captured!.ref.value, id: booking.id);
  }

  Future<Result<DepartureStateChange, DepartureTransitionRefusal>> say(
    String departureId,
    DepartureState? state, {
    String? by,
    bool mayManage = false,
  }) => console.setDepartureState(
    operatorId: PgFixture.operatorId,
    departureId: departureId,
    state: state,
    actorUserId: by ?? driver,
    actorMayManage: mayManage,
  );

  group('the crew says what happened', () {
    test('a coach leaves, and the moment is written down', () async {
      final departureId = await crewedDeparture();

      final closed = await say(departureId, DepartureState.departed);

      expect(
        closed,
        isA<Ok<DepartureStateChange, DepartureTransitionRefusal>>(),
      );
      final change =
          (closed as Ok<DepartureStateChange, DepartureTransitionRefusal>)
              .value;
      expect(change.state, DepartureState.departed);
      expect(change.changed, isTrue);
      expect(change.at, isNotNull);

      expect(await fixture.departureStatus(departureId), 'departed');
      final times = await fixture.departureTimes(departureId);
      // The fact a delay dispute actually turns on. A status column says a
      // coach has left and cannot say when.
      expect(times['departed_at'], isNotNull);
      expect(times['arrived_at'], isNull);
      expect(times['closed_by'].toString(), driver);
    });

    test('and then arrives', () async {
      final departureId = await crewedDeparture();
      await say(departureId, DepartureState.departed);

      expect(
        await say(departureId, DepartureState.arrived),
        isA<Ok<DepartureStateChange, DepartureTransitionRefusal>>(),
      );
      expect(await fixture.departureStatus(departureId), 'arrived');
    });

    // A driver on a bad connection taps twice and means it once, the same
    // rule the roster follows for a dispatcher.
    test('saying it twice is a success that writes nothing', () async {
      final departureId = await crewedDeparture();
      await say(departureId, DepartureState.departed);
      final first = await fixture.departureTimes(departureId);

      final again = await say(departureId, DepartureState.departed);

      expect(
        again,
        isA<Ok<DepartureStateChange, DepartureTransitionRefusal>>(),
      );
      final change =
          (again as Ok<DepartureStateChange, DepartureTransitionRefusal>).value;
      expect(change.changed, isFalse);
      expect(change.at, isNull);
      // The stamp is the first tap's, not the second's.
      expect(
        (await fixture.departureTimes(departureId))['departed_at'],
        first['departed_at'],
      );
    });
  });

  group('who may say it', () {
    // The reason the roster exists. A capability alone would let any driver
    // in the company close any coach in it, and closing stops sales.
    test('somebody with the role but not on this coach', () async {
      final departureId = await crewedDeparture();

      expect(
        await say(departureId, DepartureState.departed, by: stranger),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.notCrew,
        ),
      );
      expect(await fixture.departureStatus(departureId), 'scheduled');
    });

    test('a dispatcher, whose crew has no signal', () async {
      final departureId = await crewedDeparture();

      expect(
        await say(
          departureId,
          DepartureState.departed,
          by: stranger,
          mayManage: true,
        ),
        isA<Ok<DepartureStateChange, DepartureTransitionRefusal>>(),
      );
    });

    // Another operator's departure, and one that does not exist, read the
    // same: probing ids must not tell a stranger which it was.
    test("another operator's coach is not this crew's coach", () async {
      final foreign = await fixture.foreignDeparture(seatLabels: const ['1A']);

      expect(
        await say(foreign, DepartureState.departed, mayManage: true),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.notCrew,
        ),
      );
    });
  });

  group('the table, against a real row', () {
    test('a coach cannot arrive without having left', () async {
      final departureId = await crewedDeparture();

      expect(
        await say(departureId, DepartureState.arrived),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.outOfOrder,
        ),
      );
    });

    test('a coach that has left cannot un-leave', () async {
      final departureId = await crewedDeparture();
      await say(departureId, DepartureState.departed);

      expect(
        await say(departureId, DepartureState.boarding),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.alreadyClosed,
        ),
      );
      expect(await fixture.departureStatus(departureId), 'departed');
    });

    test('a cancelled coach is not put back on the road', () async {
      final departureId = await crewedDeparture();
      await fixture.setDepartureStatus(departureId, 'cancelled');

      expect(
        await say(departureId, DepartureState.departed),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.cancelled,
        ),
      );
    });

    // It has to tell everybody on board and open the re-accommodation paths.
    // A tap on a handset would do a quarter of that.
    test('cancelling is not available here, even to a dispatcher', () async {
      final departureId = await crewedDeparture();

      expect(
        await say(departureId, DepartureState.cancelled, mayManage: true),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.cancelIsADisruption,
        ),
      );
      expect(await fixture.departureStatus(departureId), 'scheduled');
    });

    test('a name that is not one of the six', () async {
      final departureId = await crewedDeparture();

      expect(
        await say(departureId, DepartureState.byName('en_route')),
        isA<Err<DepartureStateChange, DepartureTransitionRefusal>>().having(
          (e) => e.failure,
          'failure',
          DepartureTransitionRefusal.unknownState,
        ),
      );
    });
  });

  group('closing stops sales, and only sales', () {
    test('a checkout in flight is let go, not sold', () async {
      final departureId = await crewedDeparture(seatLabels: const ['1A', '1B']);
      final buyer = await fixture.traveller('7301');
      final held = await hold(
        departureId: departureId,
        seatLabels: const ['1A'],
        userId: buyer,
        idempotencyKey: key(),
      );
      final holdId = held.valueOrNull!.id;

      final closed = await say(departureId, DepartureState.departed);

      expect(
        (closed as Ok<DepartureStateChange, DepartureTransitionRefusal>)
            .value
            .holdsReleased,
        1,
        reason: 'the number a dispatcher is asked about at the counter',
      );
      expect(await fixture.holdState(holdId), 'released');
      expect(await fixture.occupancyFor(holdId), 0);

      // And the seat cannot then become a booking. `state = 'active'` on the
      // reserve path is what turns the release into a refusal rather than
      // into a passenger on a coach that is already on the RN1.
      final tooLate = await reserve(
        holdId: holdId,
        userId: buyer,
        passengers: const [PassengerDto(fullName: 'Aline M.', seatLabel: '1A')],
      );
      expect(tooLate.valueOrNull, isNull);
    });

    test('and a seat somebody paid for is left alone', () async {
      final departureId = await crewedDeparture(seatLabels: const ['1A']);
      final booking = await paid(departureId, name: 'Serge N.');

      final closed = await say(departureId, DepartureState.departed);

      expect(
        (closed as Ok<DepartureStateChange, DepartureTransitionRefusal>)
            .value
            .holdsReleased,
        0,
        reason: 'releasing this one would take a seat from somebody on board',
      );
      expect(await fixture.bookingState(booking.ref), isNot('cancelled'));
      expect(await fixture.ticketCount(booking.id), greaterThan(0));
    });

    test('no new hold can be taken on a coach that has gone', () async {
      final departureId = await crewedDeparture(seatLabels: const ['1A']);
      await say(departureId, DepartureState.departed);
      final buyer = await fixture.traveller('7302');

      final refused = await hold(
        departureId: departureId,
        seatLabels: const ['1A'],
        userId: buyer,
        idempotencyKey: key(),
      );
      expect(refused.valueOrNull, isNull);
    });

    // The claim J4 is most careful about. A passenger who boarded and is
    // sitting down has a valid ticket by definition, and the handset that
    // scanned them may not find signal until the far end.
    test('a scan uploaded after the coach left is still recorded', () async {
      final departureId = await crewedDeparture(seatLabels: const ['1A']);
      final booking = await paid(departureId);
      await say(departureId, DepartureState.departed);

      final uploaded = await console.recordBoardings(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        scannedByUserId: driver,
        boardings: [
          Boarding(
            bookingRef: booking.ref,
            seatLabel: '1A',
            scannedAt: DateTime.now().toUtc().subtract(
              const Duration(hours: 3),
            ),
            deviceId: 'handset-1',
            mode: 'scan',
            codeWasStale: false,
          ),
        ],
      );

      expect(uploaded.recorded, hasLength(1));
      expect(uploaded.unknown, isEmpty);
      // And it did not put the coach back in the yard.
      expect(await fixture.departureStatus(departureId), 'departed');
    });
  });

  group('the first scan opens the door', () {
    test('a coach enters boarding when somebody is boarded', () async {
      final departureId = await crewedDeparture(seatLabels: const ['1A']);
      final booking = await paid(departureId);
      final atTheDoor = DateTime.now().toUtc().subtract(
        const Duration(minutes: 20),
      );

      await console.recordBoardings(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        scannedByUserId: driver,
        boardings: [
          Boarding(
            bookingRef: booking.ref,
            seatLabel: '1A',
            scannedAt: atTheDoor,
            deviceId: 'handset-1',
            mode: 'scan',
            codeWasStale: false,
          ),
        ],
      );

      expect(await fixture.departureStatus(departureId), 'boarding');
      // The handset's clock, not ours: it is the only one that was at the
      // door, and a boarding stamped with the hour it found signal is
      // evidence of nothing.
      final stamped =
          (await fixture.departureTimes(departureId))['boarding_at']
              as DateTime;
      expect(
        stamped.difference(atTheDoor).abs(),
        lessThan(const Duration(seconds: 2)),
      );
    });

    test('a scan that names nobody moves nothing', () async {
      final departureId = await crewedDeparture(seatLabels: const ['1A']);

      final uploaded = await console.recordBoardings(
        operatorId: PgFixture.operatorId,
        departureId: departureId,
        scannedByUserId: driver,
        boardings: [
          Boarding(
            bookingRef: 'BEL-NOBODY',
            seatLabel: '1A',
            scannedAt: DateTime.now().toUtc(),
            deviceId: 'handset-1',
            mode: 'scan',
            codeWasStale: false,
          ),
        ],
      );

      expect(uploaded.unknown, hasLength(1));
      expect(await fixture.departureStatus(departureId), 'scheduled');
    });

    // The failure this guard exists for: a handset out of signal all morning
    // empties its outbox after the coach has arrived.
    test(
      'a late outbox cannot put an arrived coach back in the yard',
      () async {
        final departureId = await crewedDeparture(seatLabels: const ['1A']);
        final booking = await paid(departureId);
        await say(departureId, DepartureState.departed);
        await say(departureId, DepartureState.arrived);

        await console.recordBoardings(
          operatorId: PgFixture.operatorId,
          departureId: departureId,
          scannedByUserId: driver,
          boardings: [
            Boarding(
              bookingRef: booking.ref,
              seatLabel: '1A',
              scannedAt: DateTime.now().toUtc().subtract(
                const Duration(hours: 4),
              ),
              deviceId: 'handset-1',
              mode: 'scan',
              codeWasStale: false,
            ),
          ],
        );

        expect(await fixture.departureStatus(departureId), 'arrived');
      },
    );
  });
}
