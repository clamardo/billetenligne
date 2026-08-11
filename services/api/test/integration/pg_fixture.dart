import 'dart:io';

import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/application/ports/seat_inventory.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_booking_store.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
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
        ('PNR', 'CG', 'Pointe-Noire', 'Pointe-Noire'),
        ('OYO', 'CG', 'Oyo', 'Oyo'),
        ('DOL', 'CG', 'Dolisie', 'Dolisie')
      ON CONFLICT (code) DO NOTHING
    ''');
    await _seed.execute('''
      INSERT INTO routes (id, operator_id, origin_city, destination_city,
                          code, duration_minutes)
      VALUES ('$routeId', '$operatorId', 'BZV', 'PNR', 'BZV-PNR', 450)
      ON CONFLICT (id) DO NOTHING
    ''');
    // A real 2+2, thirteen rows, rather than the empty `[]` this fixture used
    // to carry. Most tests insert the seat rows they need directly and never
    // look at the sections — but a coach swap has to know **where** somebody
    // was sitting, and a layout with no sections says nobody sat anywhere.
    await _seed.execute('''
      INSERT INTO seat_layouts (id, operator_id, name, sections, capacity)
      VALUES ('$layoutId', '$operatorId', 'Coach 2+2',
              '[{"code":"STD","labelKey":"seat.class.standard",
                 "rows":13,"abreast":"2+2","startRow":1}]'::jsonb, 52)
      ON CONFLICT (id) DO UPDATE SET sections = EXCLUDED.sections
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

  /// One of our own people, with a platform role.
  ///
  /// Seeded as `postgres` because nothing in the application may write
  /// `platform_staff` — migration 0012 revokes INSERT from every running
  /// surface, on the grounds that a service which can appoint its own
  /// administrators makes every other control decorative.
  Future<String> platformStaff(String role, {String? suffix}) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO user_accounts (email, full_name)
        VALUES (@email, @name)
        ON CONFLICT (lower(email)) WHERE email IS NOT NULL
        DO UPDATE SET full_name = EXCLUDED.full_name
        RETURNING id
      '''),
      parameters: {
        'email': '$role${suffix ?? ''}@billetenligne.cg',
        'name': 'Staff $role',
      },
    );
    final userId = rows.first.toColumnMap()['id'] as String;

    await _seed.execute(
      Sql.named('''
        INSERT INTO platform_staff (user_id, role) VALUES (@user, @role)
        ON CONFLICT (user_id) DO UPDATE SET role = EXCLUDED.role,
                                            revoked_at = NULL
      '''),
      parameters: {
        'user': TypedValue(Type.uuid, userId),
        'role': TypedValue(Type.text, role),
      },
    );
    return userId;
  }

  /// An operator in a chosen lifecycle state, so the queue has something to
  /// work. Returns its id.
  Future<String> applicant({
    required String code,
    required String legalName,
    String status = 'registered',
  }) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO operators (code, legal_name, market_code, status)
        VALUES (@code, @name, 'CG', @status::operator_status)
        ON CONFLICT (code) DO UPDATE SET status = EXCLUDED.status
        RETURNING id
      '''),
      parameters: {
        'code': TypedValue(Type.text, code),
        'name': TypedValue(Type.text, legalName),
        'status': TypedValue(Type.text, status),
      },
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  Future<void> kybDocument({
    required String operatorId,
    required String docType,
    DateTime? expiresAt,
  }) async {
    await _seed.execute(
      Sql.named('''
        INSERT INTO kyb_documents (operator_id, doc_type, storage_key,
                                   expires_at)
        VALUES (@operator, @type, @key, @expires)
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'type': TypedValue(Type.text, docType),
        'key': TypedValue(Type.text, 'kyb/$operatorId/$docType.jpg'),
        'expires': TypedValue(Type.timestampTz, expiresAt),
      },
    );
  }

  Future<List<Map<String, dynamic>>> auditFor(String operatorId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT action, actor_id, actor_type, subject_type, subject_id,
               reason, before_state, after_state
          FROM audit_log WHERE operator_id = @id ORDER BY created_at
      '''),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    return [for (final row in rows) row.toColumnMap()];
  }

  /// Audit rows for one action, whichever operator they name — including
  /// the ones that name none, which is what a platform-wide read looks like.
  Future<List<Map<String, dynamic>>> auditByAction(String action) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT action, actor_id, subject_type, subject_id, reason, operator_id
          FROM audit_log WHERE action = @action ORDER BY created_at
      '''),
      parameters: {'action': TypedValue(Type.text, action)},
    );
    return [for (final row in rows) row.toColumnMap()];
  }

  /// What this account holds on this operator. Empty when they are not staff
  /// of it at all — which is what an applicant looks like right up to the
  /// moment their application is activated.
  Future<List<String>> staffRoles(String operatorId, String userId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT roles FROM operator_staff
         WHERE operator_id = @operator AND user_id = @user
           AND revoked_at IS NULL
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'user': TypedValue(Type.uuid, userId),
      },
    );
    if (rows.isEmpty) return const [];
    return [
      for (final role in rows.first.toColumnMap()['roles'] as List)
        role.toString(),
    ];
  }

  /// How many challenges carry this source **in the clear**. Always zero:
  /// `source_hash` is an HMAC, and the point of the column is that a dump of
  /// it cannot be turned back into addresses.
  Future<int> challengeSources(String source) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int FROM auth_challenges WHERE source_hash = @s',
      ),
      parameters: {'s': TypedValue(Type.text, source)},
    );
    return rows.first.first! as int;
  }

  Future<String> operatorStatus(String operatorId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT status::text AS s FROM operators WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, operatorId)},
    );
    return rows.first.toColumnMap()['s'] as String;
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

  /// What this operator negotiated when they were onboarded.
  ///
  /// A fixture writes it because the admin back office that will one day set
  /// it does not exist yet — but the column does, and the settlement path
  /// reads it, so the test can be honest about where the number comes from.
  Future<void> agreeCommission(int bps) async {
    await _seed.execute(
      Sql.named('UPDATE operators SET commission_bps = @bps WHERE id = @id'),
      parameters: {
        'bps': TypedValue(Type.integer, bps),
        'id': TypedValue(Type.uuid, operatorId),
      },
    );
  }

  /// A verified merchant number for one rail. Without one the operator has no
  /// mobile money rails at all, which is the correct default and the reason
  /// this has to be seeded explicitly.
  Future<String> collectionAccount({
    required String railId,
    required String msisdn,
    bool verified = true,
  }) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO operator_payment_accounts
          (operator_id, rail_id, msisdn, display_name, verified_at)
        VALUES (@operator, @rail, @msisdn, 'Ocean du Nord',
                CASE WHEN @verified THEN now() ELSE NULL END)
        ON CONFLICT (operator_id, rail_id) WHERE active
        DO UPDATE SET msisdn = EXCLUDED.msisdn,
                      verified_at = EXCLUDED.verified_at
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'rail': TypedValue(Type.text, railId),
        'msisdn': TypedValue(Type.text, msisdn),
        'verified': TypedValue(Type.boolean, verified),
      },
    );
    return rows.first.toColumnMap()['id'] as String;
  }

  /// The refund policy a booking was stamped with at sale time.
  ///
  /// Read from the seed connection rather than through an adapter, because
  /// the claim being made is about the *row* — ADR-0015 rule 1 says the
  /// booking keeps these two numbers forever, and an adapter that resolved
  /// them through the operator's current default would agree with itself
  /// while the rule was being broken.
  Future<({String? id, int? version})> bookingPolicy(String ref) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT refund_policy_id, refund_policy_version
          FROM bookings WHERE ref = @ref
      '''),
      parameters: {'ref': TypedValue(Type.text, ref)},
    );
    final row = rows.first.toColumnMap();
    return (
      id: row['refund_policy_id']?.toString(),
      version: row['refund_policy_version'] as int?,
    );
  }

  Future<String?> seatState(String bookingId, String label) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT state::text AS state FROM seats
         WHERE seat_label = @label
           AND departure_id = (SELECT departure_id FROM bookings WHERE id = @id)
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, bookingId),
        'label': TypedValue(Type.text, label),
      },
    );
    return rows.isEmpty ? null : rows.first.toColumnMap()['state'] as String?;
  }

  /// A seat's state on one named departure. Distinct from [seatState], which
  /// follows the booking — and after a change the booking is on the other
  /// coach, so following it would answer about the wrong seat entirely.
  Future<String?> seatStateOn(String departureId, String label) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT state::text AS state FROM seats
         WHERE seat_label = @label AND departure_id = @departure
      '''),
      parameters: {
        'departure': TypedValue(Type.uuid, departureId),
        'label': TypedValue(Type.text, label),
      },
    );
    return rows.isEmpty ? null : rows.first.toColumnMap()['state'] as String?;
  }

  /// The coach filled. A departure with zero seats is refused by the capacity
  /// constraint — rightly — so "no room" is expressed the way it happens: the
  /// seats are held, by somebody, until well past the moment being tested.
  /// `sold` would need a booking behind every seat, which the constraint
  /// insists on and which this is not trying to prove.
  Future<void> fillDeparture(String departureId) async {
    final hold = await _seed.execute(
      Sql.named('''
        INSERT INTO holds (departure_id, operator_id, seat_labels, expires_at,
                           idempotency_key)
        SELECT @id, @operator, array_agg(seat_label),
               now() + INTERVAL '2 hours', 'fixture-fill-' || @id::text
          FROM seats WHERE departure_id = @id
        RETURNING id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    await _seed.execute(
      Sql.named('''
        UPDATE seats
           SET state = 'held', hold_id = @hold,
               held_until = now() + INTERVAL '2 hours'
         WHERE departure_id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'hold': TypedValue(Type.uuid, hold.first.toColumnMap()['id']),
      },
      ignoreRows: true,
    );
  }

  Future<int> voidedTickets(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int AS n FROM tickets '
        'WHERE booking_id = @id AND voided_at IS NOT NULL',
      ),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  Future<String> bookingState(String ref) async {
    final rows = await _seed.execute(
      Sql.named('SELECT state::text AS state FROM bookings WHERE ref = @ref'),
      parameters: {'ref': TypedValue(Type.text, ref)},
    );
    return rows.first.toColumnMap()['state'] as String;
  }

  Future<int> refundCount(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int AS n FROM refunds WHERE booking_id = @id',
      ),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  /// Signed balance of one account: debits positive, credits negative.
  ///
  /// Read from `account_balances`, the view the payout run will use, rather
  /// than summed by the test — a test that computes the balance its own way
  /// proves the arithmetic it wrote, not the arithmetic that ships.
  /// A settled online sale, posted straight into the ledger.
  ///
  /// Not routed through the payment adapters: this fixture exists so a payout
  /// test has something to pay out, and building a whole mobile-money capture
  /// to produce three ledger rows would test the rail rather than the run.
  Future<void> railCapture({
    required String operatorId,
    required int fareMinor,
    required int serviceFeeMinor,
    required int commissionMinor,
    String rail = 'cg.airtel_money',
  }) async {
    final posting = Postings.railCapture(
      operatorId: operatorId,
      rail: rail,
      fare: Money(fareMinor, Currency.xaf),
      serviceFee: Money(serviceFeeMinor, Currency.xaf),
      commission: Money(commissionMinor, Currency.xaf),
    ).valueOrNull!;

    final created = await _seed.execute('SELECT gen_random_uuid() AS id');
    final txnId = created.first.toColumnMap()['id'].toString();

    // One transaction for the whole movement. The balance trigger is a
    // DEFERRABLE constraint trigger, so posting these rows one autocommitted
    // statement at a time fires it after the first entry — correctly, and
    // uselessly.
    await _seed.runTx((tx) async {
      for (final entry in posting.entries) {
        await tx.execute(
          Sql.named("""
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency,
             operator_id, memo)
          VALUES (@txn, @account, @direction::ledger_direction, @amount,
                  @currency, @operator, @memo)
        """),
          parameters: {
            'txn': TypedValue(Type.uuid, txnId),
            'account': TypedValue(Type.text, entry.account),
            'direction': TypedValue(Type.text, entry.direction.name),
            'amount': TypedValue(Type.bigInteger, entry.amount.minor),
            'currency': TypedValue(Type.text, entry.amount.currency.code),
            'operator': TypedValue(Type.uuid, entry.operatorId ?? operatorId),
            'memo': TypedValue(Type.text, entry.memo),
          },
        );
      }
    });
  }

  Future<int> accountBalance(String account) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT COALESCE(balance_minor, 0)::int AS b FROM account_balances '
        'WHERE account = @account',
      ),
      parameters: {'account': TypedValue(Type.text, account)},
    );
    return rows.isEmpty ? 0 : rows.first.toColumnMap()['b'] as int;
  }

  Future<Map<String, Object?>> intentColumns(String intentId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT state::text AS state, rail_id, msisdn, amount_minor,
               (SELECT count(*)::int FROM payment_events e
                 WHERE e.intent_id = payment_intents.id) AS events
          FROM payment_intents WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, intentId)},
    );
    return rows.first.toColumnMap();
  }

  Future<List<String>> paymentEventSources(String intentId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT source FROM payment_events WHERE intent_id = @id
         ORDER BY received_at
      '''),
      parameters: {'id': TypedValue(Type.uuid, intentId)},
    );
    return [for (final row in rows) row.toColumnMap()['source'] as String];
  }

  Future<Map<String, dynamic>> paymentEventRaw(
    String intentId,
    String source,
  ) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT raw FROM payment_events
         WHERE intent_id = @id AND source = @source
         ORDER BY received_at DESC LIMIT 1
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, intentId),
        'source': TypedValue(Type.text, source),
      },
    );
    return (rows.first.toColumnMap()['raw'] as Map).cast<String, dynamic>();
  }

  Future<int> ticketCount(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int AS n FROM tickets WHERE booking_id = @id',
      ),
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

  /// What this passenger is recorded as having paid for their seat.
  ///
  /// On `booking_seats`, not on the departure: an involuntary change carries
  /// the fare across onto a dearer coach (ADR-0016), and this is the column
  /// that would quietly disagree.
  Future<int> seatFareOnBooking(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT fare_minor::int AS fare FROM booking_seats
         WHERE booking_id = @id ORDER BY seat_label LIMIT 1
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['fare'] as int;
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

  /// How many bookings on this departure carry the operator-caused exemption.
  Future<int> involuntaryBookings(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT count(*)::int AS n FROM bookings
         WHERE departure_id = @id AND involuntary_change
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  Future<DateTime> departsAt(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT departs_at FROM departures WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return rows.first.toColumnMap()['departs_at'] as DateTime;
  }

  Future<String> departureStatus(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT status::text AS s FROM departures WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return rows.first.toColumnMap()['s'] as String;
  }

  /// Puts a departure into a state the fixture cannot reach by selling — a
  /// coach that has left, or one that arrived yesterday.
  Future<void> setDepartureStatus(String departureId, String status) async {
    await _seed.execute(
      Sql.named('''
        UPDATE departures SET status = @status::departure_status
         WHERE id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'status': TypedValue(Type.text, status),
      },
    );
  }

  /// A second road for this operator, so "a different route is a different
  /// journey" can be tested against a route that actually exists.
  Future<String> route({
    required String code,
    String origin = 'BZV',
    String destination = 'OYO',
  }) async {
    final rows = await _seed.execute(
      Sql.named('''
        INSERT INTO routes (operator_id, origin_city, destination_city,
                            code, duration_minutes)
        VALUES (@operator, @origin, @destination, @code, 300)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'origin': TypedValue(Type.text, origin),
        'destination': TypedValue(Type.text, destination),
        'code': TypedValue(Type.text, code),
      },
    );
    return rows.first.toColumnMap()['id'].toString();
  }

  /// Which departure a booking is on now. The question the rebooking wave
  /// exists to change.
  Future<String> departureOf(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT departure_id FROM bookings WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['departure_id'].toString();
  }

  Future<String?> supersededBy(String disruptionId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT superseded_by FROM disruptions WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, disruptionId)},
    );
    return rows.first.toColumnMap()['superseded_by']?.toString();
  }

  /// Who bought it. The reserve helper mints a traveller per call, and every
  /// public-surface read is keyed to that user rather than to the operator.
  Future<String> purchaserOf(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT purchaser_user_id FROM bookings WHERE id = @id'),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['purchaser_user_id'].toString();
  }

  /// The seats the live tickets are for. A moved passenger whose ticket still
  /// names the old seat scans as somebody else at the door.
  Future<List<String>> ticketSeats(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT seat_label FROM tickets
         WHERE booking_id = @id ORDER BY seat_label
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return [for (final r in rows) r.toColumnMap()['seat_label'] as String];
  }

  /// One change order's row, as the database holds it.
  Future<Map<String, Object?>?> changeOrder(String changeId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT state::text AS state, owed_minor, fee_minor, difference_minor,
               seat_labels, hold_id::text AS hold_id, applied_at
          FROM booking_changes WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  /// Ages a change order and its hold into the past, so the sweeper and the
  /// capture path can be asked what they do about one that has lapsed.
  Future<void> lapseChangeOrder(String changeId) async {
    await _seed.execute(
      Sql.named('''
        UPDATE holds
           SET created_at = now() - INTERVAL '30 minutes',
               expires_at = now() - INTERVAL '1 minute'
         WHERE id = (SELECT hold_id FROM booking_changes WHERE id = @id)
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );
    await _seed.execute(
      Sql.named('''
        UPDATE booking_changes
           SET created_at = now() - INTERVAL '30 minutes',
               expires_at = now() - INTERVAL '1 minute'
         WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, changeId)},
      ignoreRows: true,
    );
  }

  /// The nightly reliability pass's output, written directly.
  ///
  /// The pass itself is proven in the worker's suite; what this lets the
  /// catalogue suite ask is the question that belongs to it — does a figure
  /// reach a search row, and does an absent one stay absent.
  Future<void> setOnTimeRate(int? rate) async {
    await _seed.execute(
      Sql.named('UPDATE operators SET on_time_rate = @rate WHERE id = @id'),
      parameters: {
        'rate': TypedValue(Type.integer, rate),
        'id': TypedValue(Type.uuid, operatorId),
      },
      ignoreRows: true,
    );
  }

  /// What the manifest will print.
  Future<List<String>> bookingSeatLabels(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT seat_label FROM booking_seats
         WHERE booking_id = @id ORDER BY seat_label
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return [for (final r in rows) r.toColumnMap()['seat_label'] as String];
  }

  /// A second real company, so the tests that need two tenants have two.
  ///
  /// Trans Bony Voyages, which is who Océan du Nord's dispatcher finds on the
  /// forecourt when a coach fails — the counterparty in `08-disruption.md` §5
  /// and the other side of every cross-tenant check here.
  static const secondOperatorId = '22222222-2222-2222-2222-222222222222';
  static const secondOperatorCode = 'TBV';

  Future<String> secondOperator() async {
    await _seed.execute('''
      INSERT INTO operators (id, code, legal_name, market_code, status)
      VALUES ('$secondOperatorId', '$secondOperatorCode',
              'Trans Bony Voyages', 'CG', 'active')
      ON CONFLICT (id) DO NOTHING
    ''');
    return secondOperatorId;
  }

  /// Clears every agreement between two tests, so the one-live-per-pair index
  /// does not make the second test fail for the first test's reasons.
  Future<void> clearAgreements() async {
    await _seed.execute('DELETE FROM protection_corridors');
    await _seed.execute('DELETE FROM protection_movements');
    await _seed.execute('DELETE FROM protection_requests');
    await _seed.execute('DELETE FROM protection_agreements');
  }

  /// A layout belonging to a DIFFERENT operator, so the ownership checks can
  /// be tested against something that genuinely exists.
  Future<String> foreignLayout() async {
    const other = secondOperatorId;
    await secondOperator();
    final rows = await _seed.execute('''
      INSERT INTO seat_layouts (operator_id, name, sections, capacity)
      VALUES ('$other', 'Their coach', '[]'::jsonb, 40)
      RETURNING id
    ''');
    return rows.first.toColumnMap()['id'] as String;
  }

  Future<int> seatCount(String departureId) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int AS n FROM seats WHERE departure_id = @id',
      ),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return rows.first.toColumnMap()['n'] as int;
  }

  Future<Map<String, int>> seatFares(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT seat_label, fare_minor::int AS fare
          FROM seats WHERE departure_id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, departureId)},
    );
    return {
      for (final row in rows)
        row.toColumnMap()['seat_label'] as String:
            row.toColumnMap()['fare'] as int,
    };
  }

  /// Holds one seat and reserves it, through the real path.
  Future<BookingRecord> reserve({
    required Database db,
    required PostgresBookingStore bookings,
    required String departureId,
    required String seatLabel,
    required String name,
  }) async {
    final userId = await traveller(
      '${DateTime.now().microsecondsSinceEpoch % 1000000}',
      name: name,
    );

    final held = await HoldSeats(inventory: PostgresSeatInventory(db))(
      departureId: departureId,
      seatLabels: [seatLabel],
      userId: userId,
      idempotencyKey: 'fixture-${DateTime.now().microsecondsSinceEpoch}',
    );

    final reserved = await ReserveBooking(bookings: bookings)(
      holdId: held.valueOrNull!.id,
      userId: userId,
      passengers: [PassengerDto(fullName: name, seatLabel: seatLabel)],
    );
    return reserved.valueOrNull!;
  }

  /// The refund row a cancellation wrote, if it wrote one.
  Future<Map<String, Object?>?> refundFor(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT amount_minor, currency, state::text AS state, destination,
               claim_code, involuntary, reason
          FROM refunds WHERE booking_id = @id
         ORDER BY created_at DESC LIMIT 1
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  /// A party on one booking. Three people who booked together move together
  /// or not at all, and that rule needs a booking with three seats on it.
  Future<BookingRecord> reserveParty({
    required Database db,
    required PostgresBookingStore bookings,
    required String departureId,
    required List<String> seatLabels,
  }) async {
    final userId = await traveller(
      '${DateTime.now().microsecondsSinceEpoch % 1000000}',
      name: 'Famille M.',
    );

    final held = await HoldSeats(inventory: PostgresSeatInventory(db))(
      departureId: departureId,
      seatLabels: seatLabels,
      userId: userId,
      idempotencyKey: 'fixture-${DateTime.now().microsecondsSinceEpoch}',
    );

    final reserved = await ReserveBooking(bookings: bookings)(
      holdId: held.valueOrNull!.id,
      userId: userId,
      passengers: [
        for (final label in seatLabels)
          PassengerDto(fullName: 'Voyageur $label', seatLabel: label),
      ],
    );
    return reserved.valueOrNull!;
  }

  /// One journey, backdated, at whatever point it stopped.
  ///
  /// The funnel counts rows that exist because a sale happened, so the only
  /// way to test it honestly is to write those rows — a hold, and then as
  /// much of the rest as the traveller actually got through. [stoppedAt] is
  /// where they gave up:
  ///
  ///   * `hold` — held a seat and never came back (still active);
  ///   * `lapsed` — the hold timed out;
  ///   * `booking` — reached a booking and never paid;
  ///   * `refused` — reached a booking and the rail refused the payment;
  ///   * `paid` — a confirmed booking.
  ///
  /// [daysAgo] backdates the **hold**, and nothing else: that is the cohort
  /// key, and a test that backdates the booking too would pass even if the
  /// query bucketed on the wrong column.
  int _journeys = 0;

  Future<void> journey({
    required int daysAgo,
    required String stoppedAt,
    String channel = 'app',
    String? onOperator,
  }) async {
    final operator = onOperator ?? operatorId;
    final departureRows = await _seed.execute(
      Sql.named('''
        INSERT INTO departures
          (operator_id, route_id, seat_layout_id, departs_at, arrives_at,
           capacity, fare_minor, currency, status)
        VALUES (@operator, @route, @layout,
                now() + INTERVAL '30 days', now() + INTERVAL '31 days',
                4, 12000, 'XAF', 'scheduled')
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operator),
        'route': TypedValue(Type.uuid, routeId),
        'layout': TypedValue(Type.uuid, layoutId),
      },
    );
    final departureId = departureRows.first.toColumnMap()['id'].toString();

    final holdState = stoppedAt == 'hold'
        ? 'active'
        : stoppedAt == 'lapsed'
        ? 'expired'
        : 'consumed';
    final key =
        'funnel-${DateTime.now().microsecondsSinceEpoch}'
        '-${_journeys++}-$stoppedAt';

    final holdRows = await _seed.execute(
      Sql.named('''
        INSERT INTO holds (operator_id, departure_id, seat_labels, state,
                           created_at, expires_at, idempotency_key, channel)
        VALUES (@operator, @departure, ARRAY['1A'], @state::hold_state,
                now() - make_interval(days => @days::int),
                now() - make_interval(days => @days::int)
                      + INTERVAL '15 minutes',
                @key, @channel)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operator),
        'departure': TypedValue(Type.uuid, departureId),
        'state': TypedValue(Type.text, holdState),
        'days': TypedValue(Type.integer, daysAgo),
        'key': TypedValue(Type.text, key),
        'channel': TypedValue(Type.text, channel),
      },
    );
    final holdId = holdRows.first.toColumnMap()['id'].toString();
    if (stoppedAt == 'hold' || stoppedAt == 'lapsed') return;

    final bookingRows = await _seed.execute(
      Sql.named('''
        INSERT INTO bookings (ref, operator_id, departure_id, hold_id, state,
                              fare_minor, service_fee_minor, total_minor,
                              currency, channel, confirmed_at,
                              payment_method, paid_at)
        VALUES (@ref, @operator, @departure, @hold, @state::booking_state,
                12000, 0, 12000, 'XAF', @channel,
                CASE WHEN @state = 'confirmed' THEN now() END,
                CASE WHEN @state = 'confirmed' THEN @method END,
                CASE WHEN @state = 'confirmed' THEN now() END)
        RETURNING id
      '''),
      parameters: {
        // Unique per journey and short enough to look like a real one. The
        // counter is what makes two seeded in the same microsecond distinct.
        'ref': TypedValue(
          Type.text,
          'FN${_journeys.toRadixString(32)}'
                  '${DateTime.now().microsecondsSinceEpoch.toRadixString(32)}'
              .toUpperCase(),
        ),
        'operator': TypedValue(Type.uuid, operator),
        'departure': TypedValue(Type.uuid, departureId),
        'hold': TypedValue(Type.uuid, holdId),
        'state': TypedValue(
          Type.text,
          stoppedAt == 'paid' ? 'confirmed' : 'pending_payment',
        ),
        'channel': TypedValue(Type.text, channel),
        // A confirmed booking has to say how it was paid — the constraint is
        // the one that stops a ticket existing with no money behind it.
        // Mobile money whichever channel it came through: cash would need a
        // till to reconcile against, and this fixture is about the funnel.
        'method': TypedValue(Type.text, 'mobile_money'),
      },
    );
    final bookingId = bookingRows.first.toColumnMap()['id'].toString();

    if (stoppedAt == 'refused') {
      await _seed.execute(
        Sql.named('''
          INSERT INTO payment_intents (booking_id, operator_id, rail_id,
                                       amount_minor, currency, msisdn, state,
                                       idempotency_key, failure_code,
                                       terminal_at)
          VALUES (@booking, @operator, 'cg.airtel_money', 12000, 'XAF',
                  '242060000001', 'failed', @key, 'rail.declined', now())
        '''),
        parameters: {
          'booking': TypedValue(Type.uuid, bookingId),
          'operator': TypedValue(Type.uuid, operator),
          'key': TypedValue(Type.text, 'pi-$key'),
        },
      );
    }
  }

  /// A departure with [seatLabels] all available. Returns its id.
  Future<String> departure({
    required List<String> seatLabels,
    Duration fromNow = const Duration(hours: 8),
    int fareMinor = 12000,
    String status = 'scheduled',
    Duration? salesCloseIn,
    String? onRoute,
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
        'route': TypedValue(Type.uuid, onRoute ?? routeId),
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

  /// A departure belonging to the OTHER company, on their own route.
  ///
  /// Everything a protection request needs on the receiving side: a coach
  /// that is not ours, on the same road, later, with seats on it.
  Future<String> foreignDeparture({
    required List<String> seatLabels,
    Duration fromNow = const Duration(hours: 12),
    int fareMinor = 9000,
    String status = 'scheduled',
  }) async {
    await secondOperator();

    final layout = await _seed.execute(
      Sql.named('''
        INSERT INTO seat_layouts (operator_id, name, sections, capacity)
        VALUES (@operator, @name, '[]'::jsonb, @capacity)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, secondOperatorId),
        // Named per call: layouts are unique per operator and name, and a
        // test that needs two of their coaches is the ordinary case here.
        'name': TypedValue(
          Type.text,
          'Their coach ${DateTime.now().microsecondsSinceEpoch}',
        ),
        'capacity': TypedValue(Type.integer, seatLabels.length),
      },
    );

    final route = await _seed.execute(
      Sql.named('''
        INSERT INTO routes (operator_id, origin_city, destination_city,
                            code, duration_minutes)
        VALUES (@operator, 'BZV', 'PNR', @code, 450)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, secondOperatorId),
        'code': TypedValue(
          Type.text,
          'TBV-BZV-PNR-${DateTime.now().microsecondsSinceEpoch}',
        ),
      },
    );

    final created = await _seed.execute(
      Sql.named('''
        INSERT INTO departures
          (operator_id, route_id, seat_layout_id, departs_at, arrives_at,
           capacity, fare_minor, currency, status)
        VALUES (@operator, @route, @layout,
                now() + make_interval(secs => @offset),
                now() + make_interval(secs => @offset) + INTERVAL '8 hours',
                @capacity, @fare, 'XAF', @status::departure_status)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, secondOperatorId),
        'route': TypedValue(Type.uuid, route.first.toColumnMap()['id']),
        'layout': TypedValue(Type.uuid, layout.first.toColumnMap()['id']),
        'offset': TypedValue(Type.double, fromNow.inSeconds.toDouble()),
        'capacity': TypedValue(Type.integer, seatLabels.length),
        'fare': TypedValue(Type.bigInteger, fareMinor),
        'status': TypedValue(Type.text, status),
      },
    );

    final departureId = created.first.toColumnMap()['id'] as String;
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
          'operator': TypedValue(Type.uuid, secondOperatorId),
          'fare': TypedValue(Type.bigInteger, fareMinor),
        },
      );
    }
    return departureId;
  }

  /// The ledger balance of one account, signed as the ledger stores it.
  Future<int> balanceOf(String account) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT COALESCE(sum(CASE WHEN direction = 'credit' THEN amount_minor
                                 ELSE -amount_minor END), 0)::bigint AS total
          FROM ledger_entries WHERE account = @account
      '''),
      parameters: {'account': TypedValue(Type.text, account)},
    );
    final total = rows.first.toColumnMap()['total'];
    return total is int ? total : int.parse('$total');
  }

  /// Who owns a booking, and which departure it sits on. Both change when a
  /// passenger is protected onto another company's coach.
  Future<({String operatorId, String departureId})> ownerOf(
    String bookingId,
  ) async {
    final rows = await _seed.execute(
      Sql.named('''
        SELECT operator_id::text AS operator_id,
               departure_id::text AS departure_id
          FROM bookings WHERE id = @id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    final row = rows.first.toColumnMap();
    return (
      operatorId: row['operator_id']! as String,
      departureId: row['departure_id']! as String,
    );
  }

  Future<void> clearProtectionRequests() async {
    await _seed.execute('DELETE FROM protection_requests');
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

  /// How many share rows this booking has. Read under the seed connection,
  /// because the point of some of these tests is that nobody else can.
  Future<int> shareCount(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named(
        'SELECT count(*)::int AS n FROM trip_shares WHERE booking_id = @b',
      ),
      parameters: {'b': TypedValue(Type.uuid, bookingId)},
    );
    return rows.first.toColumnMap()['n']! as int;
  }

  /// What is actually stored. Never the token — that is the assertion.
  Future<List<String>> shareTokenHashes(String bookingId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT token_hash FROM trip_shares WHERE booking_id = @b'),
      parameters: {'b': TypedValue(Type.uuid, bookingId)},
    );
    return [for (final r in rows) r.toColumnMap()['token_hash']! as String];
  }

  Future<DateTime> arrivesAt(String departureId) async {
    final rows = await _seed.execute(
      Sql.named('SELECT arrives_at FROM departures WHERE id = @d'),
      parameters: {'d': TypedValue(Type.uuid, departureId)},
    );
    return (rows.first.toColumnMap()['arrives_at']! as DateTime).toUtc();
  }
}
