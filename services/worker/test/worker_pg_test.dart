@Tags(['integration'])
library;

import 'dart:io';

import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_worker/src/outbox_drain.dart';
import 'package:bel_worker/src/sweepers.dart';
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
    );
  });

  tearDownAll(() async {
    await db.close();
    await seed.close();
  });

  var seq = 0;
  String unique(String p) => '$p${++seq}${DateTime.now().microsecondsSinceEpoch % 10000}';

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

    Future<String> aConfirmedBooking() async {
      final departureId = await aDeparture();
      final userId = await aTraveller();

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
          'user': TypedValue(Type.uuid, userId),
          'station': TypedValue(Type.uuid, await aStation()),
        },
      );
      final bookingId = rows.first.toColumnMap()['id'] as String;

      await seed.execute(
        Sql.named('''
          INSERT INTO booking_seats
            (booking_id, seat_label, passenger_name, fare_minor)
          VALUES (@b, '1A', 'Aline M.', 12000)
        '''),
        parameters: {'b': TypedValue(Type.uuid, bookingId)},
      );
      return bookingId;
    }

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
}
