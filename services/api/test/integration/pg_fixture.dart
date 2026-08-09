import 'dart:io';

import 'package:bel_api/src/application/ports/seat_inventory.dart';
import 'package:postgres/postgres.dart';

/// The world a booking test needs, seeded through the front door.
///
/// Seeded as `postgres` rather than through the application, on purpose:
/// creating an operator, a route and a coach are things the *console* does
/// under a tenant scope, and building all of that first would make every
/// inventory test depend on code that does not exist yet. The fixture crosses
/// the boundary that application code is forbidden to cross, which is exactly
/// why it is confined to this file.
final class PgFixture {
  PgFixture._(this._seed);

  final Connection _seed;

  static const operatorId = '11111111-1111-1111-1111-111111111111';
  static const routeId = 'aaaaaaaa-0000-0000-0000-000000000001';
  static const layoutId = 'bbbbbbbb-0000-0000-0000-000000000001';

  /// The market's timezone. Every "which day is this?" question in these tests
  /// is asked in it, because that is the question a traveller asks.
  static const timeZone = 'Africa/Brazzaville';

  /// The URL the application connects on: `bel_api`, which is NOINHERIT and
  /// therefore has no privileges until a transaction declares its surface.
  static String get appUrl =>
      Platform.environment['DATABASE_URL'] ??
      (throw StateError(
        'DATABASE_URL is unset. Run the integration suite via '
        'tool/integration.sh, which stands up Postgres and applies the '
        'migrations.',
      ));

  /// True when this suite can run at all. Integration tests are skipped rather
  /// than failed on a machine with no Docker — a red suite that means "you did
  /// not start a container" trains people to ignore red suites.
  static bool get isAvailable =>
      (Platform.environment['DATABASE_URL'] ?? '').isNotEmpty &&
      (Platform.environment['SEED_DATABASE_URL'] ?? '').isNotEmpty;

  static Future<PgFixture> open() async {
    final seed = await Connection.open(
      _endpoint(Platform.environment['SEED_DATABASE_URL']!),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    final fixture = PgFixture._(seed);
    await fixture._seedWorld();
    return fixture;
  }

  static Endpoint _endpoint(String url) {
    final uri = Uri.parse(url);
    final auth = uri.userInfo.split(':');
    return Endpoint(
      host: uri.host,
      port: uri.port == 0 ? 5432 : uri.port,
      database: uri.pathSegments.first,
      username: auth.first,
      password: auth.length > 1 ? auth[1] : null,
    );
  }

  Future<void> _seedWorld() async {
    await _seed.execute('''
      INSERT INTO operators (id, code, legal_name, market_code, status)
      VALUES ('$operatorId', 'ODN', 'Ocean du Nord', 'CG', 'active')
      ON CONFLICT (id) DO NOTHING
    ''');
    await _seed.execute('''
      INSERT INTO cities (code, market_code, name_fr, name_en) VALUES
        ('BZV', 'CG', 'Brazzaville', 'Brazzaville'),
        ('PNR', 'CG', 'Pointe-Noire', 'Pointe-Noire')
      ON CONFLICT (code) DO NOTHING
    ''');
    await _seed.execute('''
      INSERT INTO routes (id, operator_id, origin_city, destination_city,
                          code, duration_minutes)
      VALUES ('$routeId', '$operatorId', 'BZV', 'PNR', 'BZV-PNR', 450)
      ON CONFLICT (id) DO NOTHING
    ''');
    await _seed.execute('''
      INSERT INTO seat_layouts (id, operator_id, name, sections, capacity)
      VALUES ('$layoutId', '$operatorId', 'Coach 2+2', '[]'::jsonb, 52)
      ON CONFLICT (id) DO NOTHING
    ''');
  }

  /// A traveller with an account. Returns the user id.
  Future<String> traveller(String phoneSuffix, {String? name}) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO user_accounts (phone_e164, full_name)
        VALUES (@phone, @name)
        ON CONFLICT (phone_e164) DO UPDATE SET full_name = EXCLUDED.full_name
        RETURNING id
      '''),
      parameters: {
        'phone': '+2420600$phoneSuffix',
        'name': name ?? 'Traveller $phoneSuffix',
      },
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  /// An agency counter. Cash is reconciled against the drawer that took it,
  /// so a till needs a station and a station needs a row.
  Future<String> station(String cityCode, String name) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO stations (operator_id, city_code, name)
        VALUES (@operator, @city, @name)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'city': TypedValue(Type.text, cityCode),
        'name': TypedValue(Type.text, name),
      },
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  Future<int> ledgerRowsFor(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int AS n FROM ledger_entries WHERE booking_id = @id',
      ),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  Future<int> ticketCount(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT count(*)::int AS n FROM tickets WHERE booking_id = @id'),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  /// Asked of the `ledger_txn_balances` view, never summed in Dart.
  ///
  /// A test that derives the balance itself agrees with the query by sharing
  /// its bug — the same reason the timezone tests ask Postgres what today is.
  Future<int> unbalancedTxnCount() async {
    final rows = await _seed.execute('''
      SELECT count(*)::int AS n FROM ledger_txn_balances
       WHERE balance_minor <> 0
    ''');
    return rows.first.toColumnMap()['n'] as int;
  }

  /// Signed balances per account for one booking: debits positive, credits
  /// negative, exactly as `account_balances` computes them.
  Future<Map<String, int>> accountBalances(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT account,
               SUM(CASE WHEN direction = 'debit'
                        THEN amount_minor ELSE -amount_minor END)::int AS bal
          FROM ledger_entries
         WHERE booking_id = @id
         GROUP BY account
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return {
      for (final row in rows)
        row.toColumnMap()['account'] as String: row.toColumnMap()['bal'] as int,
    };
  }

  Future<Map<String, Object?>> bookingPaymentColumns(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT payment_method, paid_at, station_id, payment_code
          FROM bookings WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap();
  }

  Future<int> outboxCount(String eventType, String aggregateId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT count(*)::int AS n FROM outbox
         WHERE event_type = @type AND aggregate_id = @id
      '''),
      parameters: {
        'type': TypedValue(Type.text, eventType),
        'id': TypedValue(Type.uuid, aggregateId),
      },
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  /// A departure with [seatLabels] all available. Returns its id.
  Future<String> departure({
    required List<String> seatLabels,
    Duration fromNow = const Duration(hours: 8),
    int fareMinor = 12000,
    String status = 'scheduled',
    Duration? salesCloseIn,
  }) async {
    final created = await _seed.execute(
      Sql.named('''
        INSERT INTO departures
          (operator_id, route_id, seat_layout_id, departs_at, arrives_at,
           capacity, fare_minor, currency, status, sales_close_at)
        VALUES
          (@operator, @route, @layout,
           now() + make_interval(secs => @offset),
           now() + make_interval(secs => @offset) + INTERVAL '8 hours',
           @capacity, @fare, 'XAF', @status::departure_status,
           CASE WHEN @closeIn::float8 IS NULL THEN NULL
                ELSE now() + make_interval(secs => @closeIn::float8) END)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'route': TypedValue(Type.uuid, routeId),
        'layout': TypedValue(Type.uuid, layoutId),
        'offset': TypedValue(Type.double, fromNow.inSeconds.toDouble()),
        'capacity': TypedValue(Type.integer, seatLabels.length),
        'fare': TypedValue(Type.bigInteger, fareMinor),
        'status': TypedValue(Type.text, status),
        'closeIn': TypedValue(
          Type.double,
          salesCloseIn == null ? null : salesCloseIn.inSeconds.toDouble(),
        ),
      },
    );

    final departureId = created.first.toColumnMap()['id'] as String;
    await _insertSeats(departureId, seatLabels, fareMinor);
    return departureId;
  }

  Future<void> _insertSeats(
    String departureId,
    List<String> seatLabels,
    int fareMinor,
  ) async {
    for (final label in seatLabels) {
      await _seed.execute(
        Sql.named('''
          INSERT INTO seats (departure_id, seat_label, operator_id,
                             section_code, fare_minor, currency)
          VALUES (@departure, @label, @operator, 'STD', @fare, 'XAF')
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'label': TypedValue(Type.text, label),
          'operator': TypedValue(Type.uuid, operatorId),
          'fare': TypedValue(Type.bigInteger, fareMinor),
        },
      );
    }
  }

  /// Reads seat states directly, bypassing the application. The test's own
  /// eyes: what the *rows* say, not what a handler reported.
  Future<Map<String, String>> seatStates(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT seat_label, state::text AS state
          FROM seats WHERE departure_id = @id ORDER BY seat_label
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return {
      for (final row in rows)
        row.toColumnMap()['seat_label'] as String:
            row.toColumnMap()['state'] as String,
    };
  }

  Future<int> countHolds(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT count(*)::int AS n FROM holds
         WHERE departure_id = @id AND state = 'active'
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  /// Ages a hold so it looks lapsed, without waiting fifteen minutes.
  ///
  /// `created_at` moves too. `holds_expire_after_creation` is a real CHECK and
  /// a fixture that quietly violates it would be testing a row shape the
  /// application can never produce.
  Future<void> expireHold(String holdId) async {
    await _seed.execute(
      Sql.named('''
        UPDATE holds
           SET created_at = now() - INTERVAL '20 minutes',
               expires_at = now() - INTERVAL '1 second'
         WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, holdId)},
    );
    await _seed.execute(
      Sql.named('''
        UPDATE seats SET held_until = now() - INTERVAL '1 second'
         WHERE hold_id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, holdId)},
    );
  }

  /// The market-local calendar date [offset] from now, as Postgres computes
  /// it.
  ///
  /// Asked of the database rather than derived in Dart, deliberately. Deriving
  /// it here would mean the test and the query agree because they share a bug,
  /// which is the classic way a timezone test passes while the feature is
  /// broken.
  Future<DateTime> localDateIn(Duration offset) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT ((now() + make_interval(secs => @offset))
                  AT TIME ZONE @tz)::date AS d
      '''),
      parameters: {
        'offset': TypedValue(Type.double, offset.inSeconds.toDouble()),
        'tz': TypedValue(Type.text, timeZone),
      },
    );
    return rows.first.toColumnMap()['d'] as DateTime;
  }

  Future<DateTime> localDateAheadOfToday(int days) =>
      localDateIn(Duration(days: days));

  /// A departure at a specific *local* hour, [daysAhead] from today.
  ///
  /// This is the fixture the timezone tests need: "the 06:00 from Brazzaville
  /// on Thursday" is a local statement, and building it from a UTC instant
  /// would ask the wrong question.
  Future<String> departureAtLocalTime({
    required List<String> seatLabels,
    required int daysAhead,
    required int localHour,
    int fareMinor = 12000,
  }) async {
    final created = await _seed.execute(
      Sql.named('''
        INSERT INTO departures
          (operator_id, route_id, seat_layout_id, departs_at, arrives_at,
           capacity, fare_minor, currency)
        VALUES
          (@operator, @route, @layout,
           ((((now() AT TIME ZONE @tz)::date + make_interval(days => @days))
             + make_interval(hours => @hour)) AT TIME ZONE @tz),
           ((((now() AT TIME ZONE @tz)::date + make_interval(days => @days))
             + make_interval(hours => @hour)) AT TIME ZONE @tz)
             + INTERVAL '8 hours',
           @capacity, @fare, 'XAF')
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'route': TypedValue(Type.uuid, routeId),
        'layout': TypedValue(Type.uuid, layoutId),
        'tz': TypedValue(Type.text, timeZone),
        'days': TypedValue(Type.integer, daysAhead),
        'hour': TypedValue(Type.integer, localHour),
        'capacity': TypedValue(Type.integer, seatLabels.length),
        'fare': TypedValue(Type.bigInteger, fareMinor),
      },
    );

    final departureId = created.first.toColumnMap()['id'] as String;
    await _insertSeats(departureId, seatLabels, fareMinor);
    return departureId;
  }

  /// A claim, so catalogue tests read as catalogue tests rather than as holds.
  SeatClaim claimFor({
    required String departureId,
    required String userId,
    required List<String> seatLabels,
    required String key,
  }) => SeatClaim(
    departureId: departureId,
    seatLabels: seatLabels,
    userId: userId,
    ttl: const Duration(minutes: 15),
    idempotencyKey: key,
  );

  Future<void> close() => _seed.close();
}
