@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_disruptions.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_worker/src/outbox_drain.dart';
import 'package:bel_worker/src/sweepers.dart';
import 'package:bel_worker/src/timetable_horizon.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// The worker, against a real database.
///
/// There is no unit suite for this file and that is deliberate: every claim
/// here is about a statement — `FOR UPDATE SKIP LOCKED`, a conditional
/// release, a backoff computed in SQL — and a fake with none of those would be
/// asserting its own behaviour rather than the worker's.
///
/// The property under test throughout is the one the design rests on: **none
/// of this is a guarantee.** A pass that never runs must cost a tidier
/// database and nothing else.
void main() {
  final url = Platform.environment['DATABASE_URL'];
  final seedUrl = Platform.environment['SEED_DATABASE_URL'];

  if (url == null || url.isEmpty || seedUrl == null || seedUrl.isEmpty) {
    test('worker suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late Database db;
  late Connection seed;
  late Sweepers sweepers;
  late OutboxDrain drain;
  late PostgresOperatorConsole console;

  const operatorId = '11111111-1111-1111-1111-111111111111';

  setUpAll(() async {
    db = Database.open(url);
    final uri = Uri.parse(seedUrl);
    final auth = uri.userInfo.split(':');
    seed = await Connection.open(
      Endpoint(
        host: uri.host,
        port: uri.port,
        database: uri.pathSegments.first,
        username: auth.first,
        password: auth.length > 1 ? auth[1] : null,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );

    sweepers = Sweepers(db);
    console = PostgresOperatorConsole(db, timeZone: 'Africa/Brazzaville');
    drain = OutboxDrain(
      db: db,
      notifications: const LoggingNotificationGateway(),
      catalog: CatalogLoader.fromDirectory(
        Platform.environment['BEL_I18N_DIR'] ??
            'packages/bel_localization/i18n',
      ),
      timeZone: 'Africa/Brazzaville',
    );

    // The API suite ran first, against this same database, and left its own
    // queued messages behind. A drain takes a hundred rows at a time, so a
    // backlog that grows past that turns "queue one and drain" into a test
    // that fails for somebody else's reasons — and fails on the day an
    // unrelated suite gains a test, which is the worst kind of red.
    await seed.execute('DELETE FROM outbox WHERE delivered_at IS NULL');
  });

  tearDownAll(() async {
    await db.close();
    await seed.close();
  });

  var seq = 0;
  String unique(String p) =>
      '$p${++seq}${DateTime.now().microsecondsSinceEpoch % 10000}';

  Future<String> aDeparture() async {
    // Every helper call makes its own route, so the board can be filtered
    // down to this test's departure. `.single` over the whole day was fine
    // for the first call and wrong for the second, which is a fixture bug
    // that looks exactly like a product bug in the output.
    final layout = await console.saveLayout(
      operatorId: operatorId,
      name: unique('W'),
      layout: SeatLayout.busStandard49(),
    );
    final vehicle = await console.saveVehicle(
      operatorId: operatorId,
      registration: unique('WK'),
      layoutId: layout.id,
    );
    final routeCode = unique('WR');
    final route = await console.saveRoute(
      operatorId: operatorId,
      code: routeCode,
      originCity: 'BZV',
      destinationCity: 'PNR',
      durationMinutes: 450,
    );
    final pattern = await console.savePattern(
      operatorId: operatorId,
      routeId: route!.id,
      recurrence: Recurrence.daily(),
      departureTime: '06:00',
      fare: const Money.xaf(12000),
      validFrom: DateTime.utc(2029, 1, 1),
      vehicleId: vehicle!.id,
    );
    await console.materialise(
      operatorId: operatorId,
      patternId: pattern!.id,
      from: DateTime.utc(2029, 1, 1),
      to: DateTime.utc(2029, 1, 1),
    );
    final board = await console.board(
      operatorId: operatorId,
      localDate: DateTime.utc(2029, 1, 1),
    );
    return board.firstWhere((row) => row.routeCode == routeCode).id;
  }

  Future<String> aTraveller() async {
    final rows = await seed.execute(
      Sql.named('''
        INSERT INTO user_accounts (phone_e164, full_name, language)
        VALUES (@phone, 'Aline M.', 'fr')
        RETURNING id
      '''),
      parameters: {'phone': '+242060${unique('')}'},
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  /// A hold written directly, so its expiry can be set in the past without
  /// waiting fifteen minutes.
  Future<String> aLapsedHold(String departureId, String userId) async {
    final rows = await seed.execute(
      Sql.named('''
        INSERT INTO holds (operator_id, departure_id, user_id, seat_labels,
                           expires_at, created_at, idempotency_key)
        VALUES (@operator, @departure, @user, ARRAY['1A'],
                now() - INTERVAL '1 minute', now() - INTERVAL '20 minutes',
                @key)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'departure': TypedValue(Type.uuid, departureId),
        'user': TypedValue(Type.uuid, userId),
        'key': TypedValue(Type.text, unique('hold')),
      },
    );
    final holdId = rows.first.toColumnMap()['id'] as String;

    await seed.execute(
      Sql.named('''
        UPDATE seats SET state = 'held', hold_id = @hold,
                         held_until = now() - INTERVAL '1 minute'
         WHERE departure_id = @departure AND seat_label = '1A'
      '''),
      parameters: {
        'hold': TypedValue(Type.uuid, holdId),
        'departure': TypedValue(Type.uuid, departureId),
      },
    );
    return holdId;
  }

  Future<String> seatState(String departureId, String label) async {
    final rows = await seed.execute(
      Sql.named('''
        SELECT state::text AS s FROM seats
         WHERE departure_id = @d AND seat_label = @l
      '''),
      parameters: {
        'd': TypedValue(Type.uuid, departureId),
        'l': TypedValue(Type.text, label),
      },
    );
    return rows.first.toColumnMap()['s'] as String;
  }

  Future<String> aStation() async {
    final rows = await seed.execute(
      Sql.named('''
        INSERT INTO stations (operator_id, city_code, name)
        VALUES (@o, 'BZV', @n) RETURNING id
      '''),
      parameters: {
        'o': TypedValue(Type.uuid, operatorId),
        'n': TypedValue(Type.text, unique('Agence ')),
      },
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  /// A paid booking on a departure that already exists, so a test can put two
  /// passengers on one coach — which is the case a disruption is about.
  Future<String> aConfirmedBookingOn(
    String departureId, {
    String seat = '1A',
  }) async {
    final rows = await seed.execute(
      Sql.named('''
        INSERT INTO bookings
          (ref, operator_id, departure_id, purchaser_user_id, state,
           fare_minor, service_fee_minor, total_minor, currency,
           payment_method, paid_at, station_id)
        VALUES (@ref, @operator, @departure, @user, 'confirmed',
                12000, 300, 12300, 'XAF', 'cash', now(), @station)
        RETURNING id
      '''),
      parameters: {
        'ref': TypedValue(Type.text, unique('R').substring(0, 6).toUpperCase()),
        'operator': TypedValue(Type.uuid, operatorId),
        'departure': TypedValue(Type.uuid, departureId),
        'user': TypedValue(Type.uuid, await aTraveller()),
        'station': TypedValue(Type.uuid, await aStation()),
      },
    );
    final bookingId = rows.first.toColumnMap()['id'] as String;

    await seed.execute(
      Sql.named('''
        INSERT INTO booking_seats
          (booking_id, seat_label, passenger_name, fare_minor)
        VALUES (@b, @seat, 'Aline M.', 12000)
      '''),
      parameters: {
        'b': TypedValue(Type.uuid, bookingId),
        'seat': TypedValue(Type.text, seat),
      },
    );
    return bookingId;
  }

  Future<DateTime> departureTime(String departureId) async {
    final rows = await seed.execute(
      Sql.named('SELECT departs_at FROM departures WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return rows.first.toColumnMap()['departs_at'] as DateTime;
  }

  group('lapsed holds', () {
    test('are expired and their seats go back on sale', () async {
      final departureId = await aDeparture();
      final holdId = await aLapsedHold(departureId, await aTraveller());

      final result = await sweepers.expireHolds();

      expect(result.affected, greaterThanOrEqualTo(1));
      expect(await seatState(departureId, '1A'), 'available');

      final state = await seed.execute(
        Sql.named("SELECT state::text AS s FROM holds WHERE id = @id"),
        parameters: {'id': TypedValue(Type.uuid, holdId)},
      );
      expect(state.first.toColumnMap()['s'], 'expired');
    });

    test('a seat sold since is not dragged back to available', () async {
      final departureId = await aDeparture();
      final holdId = await aLapsedHold(departureId, await aTraveller());

      // The sweeper arrives after the sale. `state = 'held'` in its WHERE is
      // what stops it un-selling a seat somebody paid for — which would be
      // far worse than never running at all.
      await seed.execute(
        Sql.named('''
          UPDATE seats SET state = 'sold', hold_id = NULL, held_until = NULL,
                           booking_id = gen_random_uuid()
           WHERE departure_id = @d AND seat_label = '1A'
        '''),
        parameters: {'d': TypedValue(Type.uuid, departureId)},
      );

      await sweepers.expireHolds();

      expect(await seatState(departureId, '1A'), 'sold');
      expect(holdId, isNotEmpty);
    });

    test('a live hold is left alone', () async {
      final departureId = await aDeparture();
      await seed.execute(
        Sql.named('''
          INSERT INTO holds (operator_id, departure_id, user_id, seat_labels,
                             expires_at, idempotency_key)
          VALUES (@operator, @departure, @user, ARRAY['2A'],
                  now() + INTERVAL '10 minutes', @key)
        '''),
        parameters: {
          'operator': TypedValue(Type.uuid, operatorId),
          'departure': TypedValue(Type.uuid, departureId),
          'user': TypedValue(Type.uuid, await aTraveller()),
          'key': TypedValue(Type.text, unique('live')),
        },
      );

      await sweepers.expireHolds();

      final live = await seed.execute(
        Sql.named('''
          SELECT count(*)::int AS n FROM holds
           WHERE departure_id = @d AND state = 'active'
        '''),
        parameters: {'d': TypedValue(Type.uuid, departureId)},
      );
      expect(live.first.toColumnMap()['n'], 1);
    });
  });

  group('the outbox drain', () {
    // Per test, not once per suite. "Draining twice does not send twice"
    // counts rows the drain touched, and it must count *this* test's row —
    // an expiry the sweeper group queued a moment ago is somebody else's
    // message, and a suite where one test's leftovers decide another test's
    // arithmetic goes red on the day an unrelated test is added.
    setUp(() => seed.execute('DELETE FROM outbox WHERE delivered_at IS NULL'));

    Future<int> queue(String bookingId) async {
      final rows = await seed.execute(
        Sql.named('''
          INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                              dedupe_key)
          VALUES ('booking', @id, 'booking.confirmed',
                  jsonb_build_object('bookingId', @id::text), @dedupe)
          RETURNING id
        '''),
        parameters: {
          'id': TypedValue(Type.uuid, bookingId),
          'dedupe': TypedValue(Type.text, unique('dedupe')),
        },
      );
      return rows.first.toColumnMap()['id'] as int;
    }

    Future<String> aConfirmedBooking() async =>
        aConfirmedBookingOn(await aDeparture());

    test('delivers a confirmation and marks it delivered', () async {
      final bookingId = await aConfirmedBooking();
      final rowId = await queue(bookingId);

      final result = await drain.drain();
      expect(result.affected, greaterThanOrEqualTo(1));

      final row = await seed.execute(
        Sql.named('SELECT delivered_at FROM outbox WHERE id = @id'),
        parameters: {'id': TypedValue(Type.bigInteger, rowId)},
      );
      // Marked in the same transaction the send was attempted in. The window
      // between the two is the one where a crash sends twice.
      expect(row.first.toColumnMap()['delivered_at'], isNotNull);
    });

    test('a confirmation states the time in the market, not in UTC', () async {
      final sent = FakeNotificationGateway();
      final recording = OutboxDrain(
        db: db,
        notifications: sent,
        catalog: CatalogLoader.fromDirectory(
          Platform.environment['BEL_I18N_DIR'] ??
              'packages/bel_localization/i18n',
        ),
        timeZone: 'Africa/Brazzaville',
      );

      await queue(await aConfirmedBooking());
      await recording.drain();

      // The pattern is the 06:00 from Brazzaville, which is 05:00 UTC — and
      // `timestamptz` arrives in Dart as UTC. Formatting it here would tell a
      // traveller their coach leaves an hour before it does, which is the one
      // failure in this file somebody actually misses a coach over. Postgres
      // has the zone database; Dart does not.
      expect(sent.last.body, contains('06h00'));
    });

    test('draining twice does not send twice', () async {
      final bookingId = await aConfirmedBooking();
      await queue(bookingId);

      final first = await drain.drain();
      final second = await drain.drain();

      expect(first.affected, greaterThanOrEqualTo(1));
      // Nothing erodes trust like two conflicting messages about one payment.
      expect(second.affected, 0);
    });

    test('an event nobody handles is retired, not retried forever', () async {
      await seed.execute(
        Sql.named('''
          INSERT INTO outbox (aggregate, event_type, payload, dedupe_key)
          VALUES ('thing', 'nobody.handles.this', '{}'::jsonb, @dedupe)
        '''),
        parameters: {'dedupe': TypedValue(Type.text, unique('unknown'))},
      );

      await drain.drain();

      // A producer shipped before its consumer. A queue that jams on one is a
      // queue that stops delivering everything behind it.
      final stuck = await seed.execute('''
        SELECT count(*)::int AS n FROM outbox
         WHERE event_type = 'nobody.handles.this' AND delivered_at IS NULL
      ''');
      expect(stuck.first.toColumnMap()['n'], 0);
    });
  });

  /// The message a passenger actually receives when their coach breaks down.
  ///
  /// Composed here rather than at the moment of declaration (ADR-0019 rule 1):
  /// a dispatcher standing at a roadside must not wait on an SMS gateway to
  /// find out whether their declaration was recorded.
  group('a disruption reaches the passenger', () {
    late FakeNotificationGateway sent;
    late OutboxDrain recording;
    late PostgresDisruptions desk;

    setUp(() {
      sent = FakeNotificationGateway();
      recording = OutboxDrain(
        db: db,
        notifications: sent,
        catalog: CatalogLoader.fromDirectory(
          Platform.environment['BEL_I18N_DIR'] ??
              'packages/bel_localization/i18n',
        ),
        timeZone: 'Africa/Brazzaville',
      );
      desk = PostgresDisruptions(db);
    });

    Future<String> declared({
      required DisruptionKind kind,
      required DisruptionCause cause,
      Duration? later,
      String? note,
    }) async {
      final departureId = await aDeparture();
      await aConfirmedBookingOn(departureId);
      final departsAt = await departureTime(departureId);

      final result = await desk.declare(
        operatorId: operatorId,
        departureId: departureId,
        kind: kind,
        cause: cause,
        actorUserId: await aTraveller(),
        now: DateTime.now().toUtc(),
        note: note,
        revisedDepartsAt: later == null ? null : departsAt.add(later),
      );
      expect(result.isOk, isTrue, reason: '${result.failureOrNull?.code}');
      return departureId;
    }

    /// Declares a cancellation and hands back the disruption's own id.
    Future<String> declaredOn(String departureId) async {
      final result = await desk.declare(
        operatorId: operatorId,
        departureId: departureId,
        kind: DisruptionKind.equipmentSwap,
        cause: DisruptionCause.mechanical,
        actorUserId: await aTraveller(),
        now: DateTime.now().toUtc(),
      );
      return result.valueOrNull!.id;
    }

    /// Queues one message the way the request path does — a row in the
    /// outbox, never a send inline with the dispatcher's request.
    Future<void> queue({
      required String eventType,
      required String bookingId,
      required Map<String, String> payload,
      required String dedupeKey,
    }) => seed.execute(
      Sql.named('''
        INSERT INTO outbox (aggregate, aggregate_id, event_type, payload,
                            dedupe_key)
        VALUES ('booking', @id, @type, @payload::jsonb, @key)
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, bookingId),
        'type': TypedValue(Type.text, eventType),
        'payload': TypedValue(Type.text, jsonEncode(payload)),
        'key': TypedValue(Type.text, dedupeKey),
      },
    );

    test('a refund the passenger chose says where the money is', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId, seat: '2B');

      // Approved, with a claim code — the state the choice screen leaves
      // behind (`08-disruption.md` §3.2).
      await seed.execute(
        Sql.named('''
          INSERT INTO refunds
            (booking_id, operator_id, amount_minor, currency, rate_bps,
             destination, state, involuntary, claim_code, claim_expires_at,
             requested_by, approved_by, reason)
          VALUES (@booking, @operator, 9300, 'XAF', 10000, 'agencyCash',
                  'claim_issued', TRUE, 'K7M2QRTV',
                  now() + INTERVAL '90 days', @actor, @actor, 'choice')
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'operator': TypedValue(Type.uuid, operatorId),
          'actor': TypedValue(Type.uuid, await aTraveller()),
        },
      );

      await queue(
        eventType: 'booking.refunded',
        bookingId: bookingId,
        payload: {'bookingId': bookingId},
        dedupeKey: 'booking.refunded:$bookingId',
      );

      await recording.drain();

      final body = sent.sent.last.body;
      // The code is the message. A code that only ever existed on one screen
      // is a code somebody loses, and this one is worth 9 300 francs.
      expect(body, contains('K7M2QRTV'));
      expect(body, contains('9${Money.narrowNbsp}300'));
      // And it says where: rail disbursement is a separately funded float
      // that does not exist, so promising anything but the counter would be
      // a promise the counter has to break.
      expect(body, contains('agence'));
    });

    test('a rescue coach tells the passenger their new seat', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId, seat: '7C');
      final disruptionId = await declaredOn(departureId);

      await queue(
        eventType: 'disruption.resolved',
        bookingId: bookingId,
        payload: {'bookingId': bookingId, 'disruptionId': disruptionId},
        dedupeKey: 'disruption.resolved:$disruptionId:$bookingId',
      );

      await recording.drain();

      final body = sent.sent.last.body;
      // The seat is the whole point. "Votre place est réservée, siège 7C" is
      // what turns somebody standing at a roadside into somebody waiting.
      expect(body, contains('7C'));
      expect(body, contains('BZV–PNR'));
      expect(body, contains('Aucun frais'));
    });

    test(
      'a rebooked passenger is told both times, not just the new one',
      () async {
        final broken = await aDeparture();
        final later = await aDeparture();
        // The booking has already been moved by the time the drain runs — the
        // wave commits, and the message is composed from what is now true.
        final bookingId = await aConfirmedBookingOn(later, seat: '4A');

        await queue(
          eventType: 'booking.rebooked',
          bookingId: bookingId,
          payload: {'bookingId': bookingId, 'fromDepartureId': broken},
          dedupeKey: 'booking.rebooked:$broken:$bookingId',
        );

        await recording.drain();

        final body = sent.sent.last.body;
        // Both times. The passenger has 06h00 in their head and on their
        // ticket; a message naming only the new one reads as somebody else's
        // trip.
        expect(body, contains('06h00'));
        expect(body, contains('4A'));
        expect(body, contains('Aucun frais'));
        expect(body, contains('BEL-'));
      },
    );

    test('a cancellation says who, which route, and that it is free', () async {
      await declared(
        kind: DisruptionKind.cancellation,
        cause: DisruptionCause.noVehicle,
      );

      await recording.drain();

      final body = sent.sent.last.body;
      // The operator's name, because a traveller with two bookings that
      // morning needs to know which coach this is about.
      expect(body, contains('Ocean du Nord'));
      expect(body, contains('BZV–PNR'));
      expect(body, contains("n'aura pas lieu"));
      // The first question in every passenger's mind.
      expect(body, contains('Aucun frais'));
    });

    test('a short delay carries the new time and promises nothing', () async {
      await declared(
        kind: DisruptionKind.delay,
        cause: DisruptionCause.checkpoint,
        later: const Duration(minutes: 20),
      );

      await recording.drain();

      final body = sent.sent.last.body;
      expect(body, contains('06h20'));
      // Twenty minutes entitles nobody to anything, and saying "aucun frais"
      // is a promise a counter agent has to refuse to somebody's face.
      expect(body, isNot(contains('Aucun frais')));
    });

    test("the dispatcher's own words are carried through", () async {
      await declared(
        kind: DisruptionKind.breakdownEnRoute,
        cause: DisruptionCause.mechanical,
        note: 'pont coupe a Loufoulakari',
      );

      await recording.drain();

      // No catalog can hold this sentence, which is exactly why the field
      // exists — and it is the part the passenger acts on.
      expect(sent.sent.last.body, contains('pont coupe a Loufoulakari'));
    });

    test('one message per passenger, and only once', () async {
      final departureId = await aDeparture();
      await aConfirmedBookingOn(departureId, seat: '1A');
      await aConfirmedBookingOn(departureId, seat: '1B');

      await desk.declare(
        operatorId: operatorId,
        departureId: departureId,
        kind: DisruptionKind.cancellation,
        cause: DisruptionCause.roadClosed,
        actorUserId: await aTraveller(),
        now: DateTime.now().toUtc(),
      );

      await recording.drain();
      final afterFirst = sent.sent.length;
      await recording.drain();

      expect(afterFirst, 2);
      // The dedupe key is per disruption per booking, so a drain that runs
      // twice — or two drains at once — is still one message each.
      expect(sent.sent.length, afterFirst);
    });
  });

  test('spent sign-in codes are purged after their retention window', () async {
    await seed.execute('''
      INSERT INTO auth_challenges
        (channel, destination, code_hash, expires_at, created_at)
      VALUES ('email', 'old@example.cg', 'dead', now() - INTERVAL '8 days',
              now() - INTERVAL '9 days')
    ''');

    final result = await sweepers.purgeChallenges();
    expect(result.affected, greaterThanOrEqualTo(1));

    // Kept for a week first, so "how many people bounced off sign-in" stays
    // answerable — these are personal data with no remaining purpose, not
    // rows to keep forever.
    final recent = await seed.execute('''
      SELECT count(*)::int AS n FROM auth_challenges
       WHERE destination = 'old@example.cg'
    ''');
    expect(recent.first.toColumnMap()['n'], 0);
  });
  group('the sales horizon', () {
    /// A pattern running daily from [validFrom], with a coach on it.
    Future<String> aPattern({required DateTime validFrom}) async {
      final layout = await console.saveLayout(
        operatorId: operatorId,
        name: unique('H'),
        layout: SeatLayout.busStandard49(),
      );
      final vehicle = await console.saveVehicle(
        operatorId: operatorId,
        registration: unique('HK'),
        layoutId: layout.id,
      );
      final route = await console.saveRoute(
        operatorId: operatorId,
        code: unique('HR'),
        originCity: 'BZV',
        destinationCity: 'PNR',
        durationMinutes: 450,
      );
      final pattern = await console.savePattern(
        operatorId: operatorId,
        routeId: route!.id,
        recurrence: Recurrence.daily(),
        departureTime: '06:00',
        fare: const Money.xaf(12000),
        validFrom: validFrom,
        vehicleId: vehicle!.id,
      );
      return pattern!.id;
    }

    TimetableHorizon horizonAt(DateTime now, {Duration? window}) =>
        TimetableHorizon(
          db: db,
          console: console,
          clock: FixedClock(now),
          horizon: window ?? const Duration(days: 21),
        );

    test('a rolling window is filled without anybody asking', () async {
      final today = DateTime.utc(2030, 5, 1, 3);
      await aPattern(validFrom: DateTime.utc(2030, 5, 1));

      final result = await horizonAt(
        today,
        window: const Duration(days: 6),
      ).extend();

      // Seven local days, inclusive of today.
      expect(result.affected, greaterThanOrEqualTo(7));

      final board = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2030, 5, 6),
      );
      expect(board, isNotEmpty);
    });

    test('running it twice creates nothing the second time', () async {
      final today = DateTime.utc(2030, 6, 1, 3);
      await aPattern(validFrom: DateTime.utc(2030, 6, 1));

      final first = await horizonAt(
        today,
        window: const Duration(days: 6),
      ).extend();
      final second = await horizonAt(
        today,
        window: const Duration(days: 6),
      ).extend();

      // Idempotent by construction, which is what makes a cron job that
      // overlaps yesterday's window a no-op rather than a second coach on one
      // road.
      expect(first.affected, greaterThan(0));
      expect(second.affected, 0);
    });

    test('the window rolls forward one day at a time', () async {
      final monday = DateTime.utc(2030, 7, 1, 3);
      await aPattern(validFrom: DateTime.utc(2030, 7, 1));

      await horizonAt(monday, window: const Duration(days: 3)).extend();
      final edge = await console.board(
        operatorId: operatorId,
        localDate: DateTime.utc(2030, 7, 5),
      );
      // Nothing beyond the window yet: a horizon that materialised every date
      // a rule allows would write a million seat rows for a timetable that
      // will be edited next month.
      expect(edge, isEmpty);

      final tomorrow = await horizonAt(
        monday.add(const Duration(days: 1)),
        window: const Duration(days: 3),
      ).extend();

      // Exactly the one new day at the far edge.
      expect(tomorrow.affected, greaterThan(0));
      expect(
        await console.board(
          operatorId: operatorId,
          localDate: DateTime.utc(2030, 7, 5),
        ),
        isNotEmpty,
      );
    });

    test('a suspended operator gains no inventory overnight', () async {
      final today = DateTime.utc(2030, 8, 1, 3);
      final patternId = await aPattern(validFrom: DateTime.utc(2030, 8, 1));

      await seed.execute(
        Sql.named("UPDATE operators SET status = 'suspended' WHERE id = @id"),
        parameters: {'id': TypedValue(Type.uuid, operatorId)},
      );
      addTearDown(() async {
        await seed.execute(
          Sql.named("UPDATE operators SET status = 'active' WHERE id = @id"),
          parameters: {'id': TypedValue(Type.uuid, operatorId)},
        );
      });

      final result = await horizonAt(
        today,
        window: const Duration(days: 6),
      ).extend();

      // Their existing departures are the lifecycle path's business. This
      // pass simply stops adding to them.
      expect(result.affected, 0);
      expect(patternId, isNotEmpty);
    });

    test('an inactive pattern is left alone', () async {
      final today = DateTime.utc(2030, 9, 1, 3);
      final patternId = await aPattern(validFrom: DateTime.utc(2030, 9, 1));
      await seed.execute(
        Sql.named(
          'UPDATE departure_patterns SET active = FALSE WHERE id = @id',
        ),
        parameters: {'id': TypedValue(Type.uuid, patternId)},
      );

      await horizonAt(today, window: const Duration(days: 6)).extend();

      // Not `result.affected`: other patterns in this suite are still live,
      // and the pass is deliberately cross-tenant. The claim is about this
      // pattern, so the assertion has to be about this pattern.
      final rows = await seed.execute(
        Sql.named('SELECT count(*) FROM departures WHERE pattern_id = @id'),
        parameters: {'id': TypedValue(Type.uuid, patternId)},
      );
      expect(rows.first.first, 0);
    });

    test('a backlog is reported rather than silently truncated', () async {
      final today = DateTime.utc(2030, 10, 1, 3);
      await aPattern(validFrom: DateTime.utc(2030, 10, 1));
      await aPattern(validFrom: DateTime.utc(2030, 10, 1));

      final result = await horizonAt(
        today,
        window: const Duration(days: 2),
      ).extend(limit: 1);

      // A scheduler running once a day against a hundred operators should see
      // a visible problem, not a silent backlog.
      expect(result.name, contains('more due'));
    });
  });
}
