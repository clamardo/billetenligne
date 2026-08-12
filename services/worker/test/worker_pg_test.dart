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
import 'package:bel_worker/src/reliability.dart';
import 'package:bel_worker/src/seat_alerts.dart';
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
  late Reliability reliability;
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
    reliability = Reliability(db);
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

  /// Padded, and deliberately: a booking ref is cut to six characters below,
  /// and a clock that happens to land on a low microsecond count produced a
  /// shorter string and a fixture that failed perhaps one run in ten.
  String unique(String p) =>
      '$p${++seq}${(DateTime.now().microsecondsSinceEpoch % 10000).toString().padLeft(4, '0')}';

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

  group('lapsed change orders', () {
    /// An order whose window has closed, holding [seat] on [departureId].
    Future<String> aLapsedOrder(
      String departureId,
      String bookingId, {
      bool inFlight = false,
    }) async {
      final hold = await seed.execute(
        Sql.named('''
          INSERT INTO holds (operator_id, departure_id, seat_labels,
                             expires_at, created_at, idempotency_key)
          VALUES (@operator, @departure, ARRAY['2A'],
                  now() - INTERVAL '1 minute', now() - INTERVAL '20 minutes',
                  @key)
          RETURNING id
        '''),
        parameters: {
          'operator': TypedValue(Type.uuid, operatorId),
          'departure': TypedValue(Type.uuid, departureId),
          'key': TypedValue(Type.text, unique('chg-hold')),
        },
      );

      final rows = await seed.execute(
        Sql.named('''
          INSERT INTO booking_changes
            (booking_id, operator_id, from_departure_id, to_departure_id,
             seat_labels, hold_id, owed_minor, currency, expires_at,
             created_at)
          SELECT @booking, @operator, b.departure_id, @departure, ARRAY['2A'],
                 @hold, 1500, 'XAF', now() - INTERVAL '1 minute',
                 now() - INTERVAL '20 minutes'
            FROM bookings b WHERE b.id = @booking
          RETURNING id
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'operator': TypedValue(Type.uuid, operatorId),
          'departure': TypedValue(Type.uuid, departureId),
          'hold': TypedValue(Type.uuid, hold.first.toColumnMap()['id']),
        },
      );
      final changeId = rows.first.toColumnMap()['id'] as String;

      if (inFlight) {
        await seed.execute(
          Sql.named('''
            INSERT INTO payment_intents
              (booking_id, operator_id, rail_id, msisdn, amount_minor,
               currency, state, idempotency_key, change_id)
            VALUES (@booking, @operator, 'cg.fake_money', '242060000002',
                    1500, 'XAF', 'pending', @key, @change)
          '''),
          parameters: {
            'booking': TypedValue(Type.uuid, bookingId),
            'operator': TypedValue(Type.uuid, operatorId),
            'key': TypedValue(Type.text, unique('chg-intent')),
            'change': TypedValue(Type.uuid, changeId),
          },
        );
      }

      return changeId;
    }

    Future<String> orderState(String changeId) async {
      final rows = await seed.execute(
        Sql.named(
          'SELECT state::text AS s FROM booking_changes WHERE id = @id',
        ),
        parameters: {'id': TypedValue(Type.uuid, changeId)},
      );
      return rows.first.toColumnMap()['s'] as String;
    }

    test('are closed once their seats have gone back on sale', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId);
      final target = await aDeparture();
      final changeId = await aLapsedOrder(target, bookingId);

      final result = await sweepers.expireChangeOrders();

      expect(result.affected, greaterThanOrEqualTo(1));
      expect(await orderState(changeId), 'expired');
    });

    test('one with a prompt still in flight is left alone', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId);
      final target = await aDeparture();
      final changeId = await aLapsedOrder(target, bookingId, inFlight: true);

      await sweepers.expireChangeOrders();

      // The money may yet land. Expiring it here would leave a live prompt
      // pointing at an order nothing can apply, which is a state nobody can
      // see; the capture path closes it instead, and leaves an intent a human
      // can find and refund.
      expect(await orderState(changeId), 'awaiting_payment');
    });

    test('a live order is left alone', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId);
      final target = await aDeparture();

      final hold = await seed.execute(
        Sql.named('''
          INSERT INTO holds (operator_id, departure_id, seat_labels,
                             expires_at, idempotency_key)
          VALUES (@operator, @departure, ARRAY['2A'],
                  now() + INTERVAL '10 minutes', @key)
          RETURNING id
        '''),
        parameters: {
          'operator': TypedValue(Type.uuid, operatorId),
          'departure': TypedValue(Type.uuid, target),
          'key': TypedValue(Type.text, unique('chg-live')),
        },
      );

      final rows = await seed.execute(
        Sql.named('''
          INSERT INTO booking_changes
            (booking_id, operator_id, from_departure_id, to_departure_id,
             seat_labels, hold_id, owed_minor, currency, expires_at)
          VALUES (@booking, @operator, @from, @departure, ARRAY['2A'], @hold,
                  1500, 'XAF', now() + INTERVAL '10 minutes')
          RETURNING id
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'operator': TypedValue(Type.uuid, operatorId),
          'from': TypedValue(Type.uuid, departureId),
          'departure': TypedValue(Type.uuid, target),
          'hold': TypedValue(Type.uuid, hold.first.toColumnMap()['id']),
        },
      );

      await sweepers.expireChangeOrders();

      expect(
        await orderState(rows.first.toColumnMap()['id'] as String),
        'awaiting_payment',
      );
    });
  });

  group('the on-time figure', () {
    /// [total] departures in the past, of which [disrupted] had something
    /// declared about them. Written directly: materialising ninety days of a
    /// pattern to prove an arithmetic rule would test the horizon pass.
    Future<void> ranCoaches({required int total, int disrupted = 0}) async {
      await seed.execute(
        Sql.named("DELETE FROM disruptions WHERE operator_id = @o"),
        parameters: {'o': TypedValue(Type.uuid, operatorId)},
        ignoreRows: true,
      );
      await seed.execute(
        Sql.named('''
          DELETE FROM departures
           WHERE operator_id = @o AND departs_at < now()
        '''),
        parameters: {'o': TypedValue(Type.uuid, operatorId)},
        ignoreRows: true,
      );

      for (var i = 0; i < total; i++) {
        final rows = await seed.execute(
          Sql.named('''
            INSERT INTO departures
              (operator_id, route_id, seat_layout_id, departs_at, arrives_at,
               capacity, fare_minor, currency)
            SELECT @o, r.id, l.id,
                   now() - make_interval(days => @day::int),
                   now() - make_interval(days => @day::int)
                     + INTERVAL '6 hours',
                   49, 12000, 'XAF'
              FROM routes r, seat_layouts l
             WHERE r.operator_id = @o AND l.operator_id = @o
             LIMIT 1
            RETURNING id
          '''),
          parameters: {
            'o': TypedValue(Type.uuid, operatorId),
            'day': TypedValue(Type.integer, i % 60 + 1),
          },
        );

        if (i < disrupted) {
          await seed.execute(
            Sql.named('''
              INSERT INTO disruptions
                (operator_id, departure_id, kind, cause, marks_involuntary,
                 resolved_at)
              VALUES (@o, @d, 'delay', 'breakdown', TRUE, now())
            '''),
            parameters: {
              'o': TypedValue(Type.uuid, operatorId),
              'd': TypedValue(Type.uuid, rows.first.toColumnMap()['id']),
            },
            ignoreRows: true,
          );
        }
      }
    }

    Future<({int? rate, int sample})> scoreboard() async {
      final rows = await seed.execute(
        Sql.named('''
          SELECT on_time_rate, reliability_sample
            FROM operators WHERE id = @o
        '''),
        parameters: {'o': TypedValue(Type.uuid, operatorId)},
      );
      final row = rows.first.toColumnMap();
      return (
        rate: row['on_time_rate'] as int?,
        sample: row['reliability_sample'] as int,
      );
    }

    test('is the share of coaches nobody had to explain', () async {
      await ranCoaches(total: 25, disrupted: 5);

      final result = await reliability.recompute();

      expect(result.affected, greaterThanOrEqualTo(1));
      final score = await scoreboard();
      expect(score.rate, 80);
      expect(score.sample, 25);
    });

    test('too little history is no figure at all', () async {
      await ranCoaches(total: 4, disrupted: 1);

      await reliability.recompute();

      // Four departures and one breakdown is not "75 % on time"; it is an
      // operator nobody knows about yet, and a blank says that honestly.
      final score = await scoreboard();
      expect(score.rate, isNull);
      expect(score.sample, 4);
    });

    test('an old bad quarter stops counting', () async {
      await ranCoaches(total: 25, disrupted: 25);

      // Every one of them declared, but all of them outside the window.
      await seed.execute(
        Sql.named('''
          UPDATE departures
             SET departs_at = now() - INTERVAL '200 days',
                 arrives_at = now() - INTERVAL '200 days' + INTERVAL '6 hours'
           WHERE operator_id = @o AND departs_at < now()
        '''),
        parameters: {'o': TypedValue(Type.uuid, operatorId)},
        ignoreRows: true,
      );

      await reliability.recompute();

      final score = await scoreboard();
      expect(score.sample, 0);
      expect(score.rate, isNull);
    });

    test('a coach that has not run yet says nothing either way', () async {
      await ranCoaches(total: 25);
      await reliability.recompute();
      final before = await scoreboard();

      // Tomorrow's departures are not evidence about yesterday's operator.
      await aDeparture();
      await reliability.recompute();

      expect((await scoreboard()).sample, before.sample);
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

    test('a cancellation the traveller made carries the code', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId, seat: '3C');

      await seed.execute(
        Sql.named('''
          INSERT INTO refunds
            (booking_id, operator_id, amount_minor, currency, rate_bps,
             destination, state, involuntary, claim_code, claim_expires_at,
             requested_by, approved_by, reason)
          VALUES (@booking, @operator, 8100, 'XAF', 9000, 'agencyCash',
                  'claim_issued', FALSE, 'QRTVK7M2',
                  now() + INTERVAL '90 days', @actor, @actor,
                  'cancelled by the traveller')
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'operator': TypedValue(Type.uuid, operatorId),
          'actor': TypedValue(Type.uuid, await aTraveller()),
        },
      );

      await queue(
        eventType: 'booking.cancelled',
        bookingId: bookingId,
        payload: {'bookingId': bookingId},
        dedupeKey: 'booking.cancelled:$bookingId',
      );

      await recording.drain();

      final body = sent.sent.last.body;
      expect(body, contains('QRTVK7M2'));
      expect(body, contains('8${Money.narrowNbsp}100'));
      expect(body, contains('agence'));
    });

    test('a cancellation refunded to a wallet promises a window, not an '
        'arrival', () async {
      final departureId = await aDeparture();
      final bookingId = await aConfirmedBookingOn(departureId, seat: '4D');

      // No claim code: the money goes back down the rail it came from, which
      // is a separately funded float that does not exist yet. The row says
      // what is owed and the message must not say it has been sent.
      await seed.execute(
        Sql.named('''
          INSERT INTO refunds
            (booking_id, operator_id, amount_minor, currency, rate_bps,
             destination, state, involuntary, requested_by, approved_by,
             reason)
          VALUES (@booking, @operator, 8100, 'XAF', 9000, 'source',
                  'approved', FALSE, @actor, @actor,
                  'cancelled by the traveller')
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'operator': TypedValue(Type.uuid, operatorId),
          'actor': TypedValue(Type.uuid, await aTraveller()),
        },
      );

      await queue(
        eventType: 'booking.cancelled',
        bookingId: bookingId,
        payload: {'bookingId': bookingId},
        dedupeKey: 'booking.cancelled:$bookingId',
      );

      await recording.drain();

      final body = sent.sent.last.body;
      expect(body, contains('72h'));
      expect(body, isNot(contains('code')));
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
  // Three minutes, not the default thirty seconds. This pass materialises a
  // rolling window over **every** active pattern in the database, and the
  // integration database is shared with the API suite — so the work each
  // test here does grows with the whole repository's fixtures, not with the
  // one pattern the test wrote. The alternative is a test that goes red the
  // day somebody adds a timetable fixture three packages away.
  group('the sales horizon', timeout: const Timeout(Duration(minutes: 3)), () {
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

  group('somebody waiting for a seat', () {
    late SeatAlertPass alerts;
    late FakeNotificationGateway sent;
    late OutboxDrain recording;

    setUp(() {
      alerts = SeatAlertPass(db);
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
    });

    /// Every seat on a coach held for two hours: a full coach.
    Future<void> fill(String departureId) async {
      final hold = await seed.execute(
        Sql.named('''
          INSERT INTO holds (operator_id, departure_id, seat_labels,
                             expires_at, idempotency_key)
          SELECT @operator, @departure, array_agg(seat_label),
                 now() + INTERVAL '2 hours', @key
            FROM seats WHERE departure_id = @departure
          RETURNING id
        '''),
        parameters: {
          'operator': TypedValue(Type.uuid, operatorId),
          'departure': TypedValue(Type.uuid, departureId),
          'key': TypedValue(Type.text, unique('fill')),
        },
      );
      await seed.execute(
        Sql.named('''
          UPDATE seats SET state = 'held', hold_id = @hold,
                           held_until = now() + INTERVAL '2 hours'
           WHERE departure_id = @departure
        '''),
        parameters: {
          'hold': TypedValue(Type.uuid, hold.first.toColumnMap()['id']),
          'departure': TypedValue(Type.uuid, departureId),
        },
        ignoreRows: true,
      );
    }

    /// Puts [count] seats back on sale — a cancellation, or a hold nobody
    /// paid for that the hold sweeper has already been past.
    Future<void> free(String departureId, {int count = 1}) => seed.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'available', hold_id = NULL, held_until = NULL
         WHERE departure_id = @departure
           AND seat_label IN (SELECT seat_label FROM seats
                               WHERE departure_id = @departure
                                 AND state = 'held'
                               ORDER BY seat_label LIMIT @n)
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'n': TypedValue(Type.integer, count),
      },
      ignoreRows: true,
    );

    Future<String> waitingOn(
      String departureId,
      String userId, {
      int seats = 1,
    }) async {
      final rows = await seed.execute(
        Sql.named('''
          INSERT INTO seat_alerts (departure_id, user_id, seats_wanted)
          VALUES (@departure, @user, @seats)
          RETURNING id
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'user': TypedValue(Type.uuid, userId),
          'seats': TypedValue(Type.integer, seats),
        },
      );
      return rows.first.toColumnMap()['id'] as String;
    }

    Future<DateTime?> notifiedAt(String alertId) async {
      final rows = await seed.execute(
        Sql.named('SELECT notified_at FROM seat_alerts WHERE id = @id'),
        parameters: {'id': TypedValue(Type.uuid, alertId)},
      );
      return rows.first.toColumnMap()['notified_at'] as DateTime?;
    }

    test('a full coach queues nothing', () async {
      final departureId = await aDeparture();
      await fill(departureId);
      final alertId = await waitingOn(departureId, await aTraveller());

      await alerts.notify();

      // The whole point of the row is that it has not fired.
      expect(await notifiedAt(alertId), isNull);
    });

    test('a freed seat tells everybody waiting, at once', () async {
      // Not a queue. Both are told in the same pass, and the first to pay
      // gets the seat — which is the only promise this system can keep when
      // the same inventory is on sale to the whole market.
      final departureId = await aDeparture();
      await fill(departureId);
      final first = await waitingOn(departureId, await aTraveller());
      final second = await waitingOn(departureId, await aTraveller());
      await free(departureId);

      await alerts.notify();

      expect(await notifiedAt(first), isNotNull);
      expect(await notifiedAt(second), isNotNull);
    });

    test('it fires once, and a second pass finds nothing', () async {
      // A seat that came free and went again is not news worth a second SMS.
      final departureId = await aDeparture();
      await fill(departureId);
      await waitingOn(departureId, await aTraveller());
      await free(departureId);

      await alerts.notify();
      final again = await alerts.notify();

      expect(again.affected, 0);
    });

    test('a party larger than the room is not told', () async {
      // One seat is not news to a family of three. Telling them anyway is a
      // wasted journey to a station dressed up as good news.
      final departureId = await aDeparture();
      await fill(departureId);
      final alertId = await waitingOn(
        departureId,
        await aTraveller(),
        seats: 3,
      );
      await free(departureId);

      await alerts.notify();
      expect(await notifiedAt(alertId), isNull);

      await free(departureId, count: 2);
      await alerts.notify();
      expect(await notifiedAt(alertId), isNotNull);
    });

    test('a coach that has left is closed, not left waiting', () async {
      final departureId = await aDeparture();
      await fill(departureId);
      final alertId = await waitingOn(departureId, await aTraveller());

      await seed.execute(
        Sql.named('''
          UPDATE departures
             SET departs_at = now() - INTERVAL '1 hour', status = 'departed'
           WHERE id = @id
        '''),
        parameters: {'id': TypedValue(Type.uuid, departureId)},
        ignoreRows: true,
      );

      await alerts.expire();

      // Cancelled, never notified: nothing was sent. A row left waiting for
      // ever would be examined by every pass, and would answer "am I still
      // waiting?" with a yes that is no longer possible.
      final rows = await seed.execute(
        Sql.named('''
          SELECT notified_at, cancelled_at FROM seat_alerts WHERE id = @id
        '''),
        parameters: {'id': TypedValue(Type.uuid, alertId)},
      );
      final row = rows.first.toColumnMap();
      expect(row['notified_at'], isNull);
      expect(row['cancelled_at'], isNotNull);
    });

    test('the message says back on sale, never reserved for you', () async {
      final departureId = await aDeparture();
      await fill(departureId);
      final alertId = await waitingOn(
        departureId,
        await aTraveller(),
        seats: 2,
      );
      await free(departureId, count: 2);

      await alerts.notify();
      await recording.drain();

      // Found by event id rather than taken as the only one: earlier tests in
      // this group left their own alerts queued, and a drain takes a hundred
      // rows at a time.
      final message = sent.sent.singleWhere(
        (m) => m.eventId == 'seat.available:$alertId',
      );
      expect(message.body, contains('BZV–PNR'));
      // Two seats, because that is what was asked for.
      expect(message.body, startsWith('2 '));
      // The sentence that stops somebody travelling to a station for a coach
      // that filled while they were reading about it.
      expect(message.body, contains('Premier arrive'));
    });
  });
}
