import 'dart:convert';

import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/operator_console.dart';
import '../db/database.dart';

/// The console, on the tenant surface.
///
/// Every statement runs under `DbScope.tenant`, so RLS is the first line of
/// defence and the `WHERE operator_id = @operator` clauses below are the
/// second (ADR-0011). Both are present on purpose: if one of these queries
/// ever loses its clause the database still refuses, and if a policy is ever
/// mis-written the query still scopes.
final class PostgresOperatorConsole implements OperatorConsole {
  const PostgresOperatorConsole(this._db, {required this.timeZone});

  final Database _db;

  /// The market's zone. Every "which day is this?" question here is asked in
  /// it, because a timetable is a local fact — "the 06:00 from Brazzaville" is
  /// not an instant, and materialising it from a UTC date puts the coach on
  /// the wrong day for a country an hour off UTC.
  final String timeZone;

  // ── Fleet ─────────────────────────────────────────────────────────────────

  @override
  Future<List<LayoutSummary>> layouts(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT l.id, l.name, l.version, l.capacity, l.mode,
                   count(v.id)::int AS vehicle_count
              FROM seat_layouts l
              LEFT JOIN vehicles v ON v.seat_layout_id = l.id
             WHERE l.operator_id = @operator
             GROUP BY l.id
             ORDER BY l.name, l.version DESC
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return [
          for (final row in rows)
            LayoutSummary(
              id: row.toColumnMap()['id'].toString(),
              name: row.toColumnMap()['name'] as String,
              version: row.toColumnMap()['version'] as int,
              capacity: row.toColumnMap()['capacity'] as int,
              mode: row.toColumnMap()['mode'] as String,
              vehicleCount: row.toColumnMap()['vehicle_count'] as int,
            ),
        ];
      });

  @override
  Future<LayoutSummary> saveLayout({
    required String operatorId,
    required String name,
    required SeatLayout layout,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // A NEW VERSION, never an edit. A departure keeps the layout it was sold
    // with, so changing a template must not be able to renumber a seat
    // somebody already bought — the same rule refund policies follow
    // (ADR-0015), and for the same reason.
    final next = await tx.execute(
      Sql.named('''
        SELECT COALESCE(MAX(version), 0) + 1 AS v
          FROM seat_layouts WHERE operator_id = @operator AND name = @name
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'name': TypedValue(Type.text, name),
      },
    );
    final version = next.first.toColumnMap()['v'] as int;

    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO seat_layouts
          (operator_id, name, version, mode, sections, features, blocked,
           capacity)
        VALUES (@operator, @name, @version, @mode, @sections::jsonb,
                @features::jsonb, @blocked, @capacity)
        RETURNING id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'name': TypedValue(Type.text, name),
        'version': TypedValue(Type.integer, version),
        'mode': TypedValue(Type.text, layout.mode.name),
        'sections': TypedValue(Type.text, jsonEncode(_sections(layout))),
        'features': TypedValue(Type.text, jsonEncode(_features(layout))),
        'blocked': TypedValue(Type.textArray, layout.blocked.toList()),
        'capacity': TypedValue(Type.integer, layout.capacity),
      },
    );

    return LayoutSummary(
      id: rows.first.toColumnMap()['id'].toString(),
      name: name,
      version: version,
      capacity: layout.capacity,
      mode: layout.mode.name,
      vehicleCount: 0,
    );
  });

  @override
  Future<List<VehicleSummary>> vehicles(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT v.id, v.registration, v.nickname, v.model, v.amenities,
                   v.status, v.seat_layout_id, l.name AS layout_name,
                   l.capacity
              FROM vehicles v
              JOIN seat_layouts l ON l.id = v.seat_layout_id
             WHERE v.operator_id = @operator
             ORDER BY v.registration
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );
        return [for (final row in rows) _vehicle(row.toColumnMap())];
      });

  @override
  Future<VehicleSummary?> saveVehicle({
    required String operatorId,
    required String registration,
    required String layoutId,
    String? id,
    String? nickname,
    String? model,
    List<String> amenities = const [],
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // The layout must be this operator's. Without the check, one operator
    // could point a coach at a competitor's template and read its capacity
    // and section names out of the seat map.
    final owned = await tx.execute(
      Sql.named('''
        SELECT mode FROM seat_layouts
         WHERE id = @layout AND operator_id = @operator
      '''),
      parameters: {
        'layout': TypedValue(Type.uuid, layoutId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    if (owned.isEmpty) return null;
    final mode = owned.first.toColumnMap()['mode'] as String;

    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO vehicles
          (id, operator_id, seat_layout_id, mode, registration, nickname,
           model, amenities)
        VALUES (COALESCE(@id, gen_random_uuid()), @operator, @layout, @mode,
                @registration, @nickname, @model, @amenities)
        ON CONFLICT (operator_id, registration) DO UPDATE
           SET seat_layout_id = EXCLUDED.seat_layout_id,
               nickname = EXCLUDED.nickname,
               model = EXCLUDED.model,
               amenities = EXCLUDED.amenities
        RETURNING id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, id),
        'operator': TypedValue(Type.uuid, operatorId),
        'layout': TypedValue(Type.uuid, layoutId),
        'mode': TypedValue(Type.text, mode),
        'registration': TypedValue(Type.text, registration),
        'nickname': TypedValue(Type.text, nickname),
        'model': TypedValue(Type.text, model),
        'amenities': TypedValue(Type.textArray, amenities),
      },
    );

    final saved = await tx.execute(
      Sql.named('''
        SELECT v.id, v.registration, v.nickname, v.model, v.amenities,
               v.status, v.seat_layout_id, l.name AS layout_name, l.capacity
          FROM vehicles v
          JOIN seat_layouts l ON l.id = v.seat_layout_id
         WHERE v.id = @id
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, rows.first.toColumnMap()['id'].toString()),
      },
    );
    return _vehicle(saved.first.toColumnMap());
  });

  @override
  Future<List<String>> setVehicleStatus({
    required String operatorId,
    required String vehicleId,
    required String status,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    await tx.execute(
      Sql.named('''
        UPDATE vehicles SET status = @status
         WHERE id = @id AND operator_id = @operator
      '''),
      parameters: {
        'status': TypedValue(Type.text, status),
        'id': TypedValue(Type.uuid, vehicleId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
      ignoreRows: true,
    );

    if (status == 'active') return const [];

    // Every future departure this coach was going to run. Returned rather
    // than silently left: taking a vehicle off the road without saying which
    // departures it was carrying is how bookings get dropped without anybody
    // noticing until the passengers are at the station.
    final affected = await tx.execute(
      Sql.named('''
        SELECT id FROM departures
         WHERE vehicle_id = @id
           AND operator_id = @operator
           AND departs_at > now()
           AND status <> 'cancelled'
         ORDER BY departs_at
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, vehicleId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    return [for (final row in affected) row.toColumnMap()['id'].toString()];
  });

  // ── Network ───────────────────────────────────────────────────────────────

  @override
  Future<List<RouteSummary>> routes(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT id, code, origin_city, destination_city, duration_minutes,
                   active
              FROM routes WHERE operator_id = @operator ORDER BY code
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return [
          for (final row in rows)
            RouteSummary(
              id: row.toColumnMap()['id'].toString(),
              code: row.toColumnMap()['code'] as String,
              originCity: row.toColumnMap()['origin_city'] as String,
              destinationCity:
                  row.toColumnMap()['destination_city'] as String,
              durationMinutes: row.toColumnMap()['duration_minutes'] as int,
              active: row.toColumnMap()['active'] as bool,
            ),
        ];
      });

  @override
  Future<RouteSummary?> saveRoute({
    required String operatorId,
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    int? distanceKm,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    if (originCity == destinationCity) return null;

    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO routes
          (id, operator_id, origin_city, destination_city, code,
           duration_minutes, distance_km)
        VALUES (COALESCE(@id, gen_random_uuid()), @operator, @origin,
                @destination, @code, @duration, @distance)
        ON CONFLICT (operator_id, code) DO UPDATE
           SET origin_city = EXCLUDED.origin_city,
               destination_city = EXCLUDED.destination_city,
               duration_minutes = EXCLUDED.duration_minutes,
               distance_km = EXCLUDED.distance_km
        RETURNING id, code, origin_city, destination_city, duration_minutes,
                  active
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, id),
        'operator': TypedValue(Type.uuid, operatorId),
        'origin': TypedValue(Type.text, originCity),
        'destination': TypedValue(Type.text, destinationCity),
        'code': TypedValue(Type.text, code),
        'duration': TypedValue(Type.integer, durationMinutes),
        'distance': TypedValue(Type.integer, distanceKm),
      },
    );

    final row = rows.first.toColumnMap();
    return RouteSummary(
      id: row['id'].toString(),
      code: row['code'] as String,
      originCity: row['origin_city'] as String,
      destinationCity: row['destination_city'] as String,
      durationMinutes: row['duration_minutes'] as int,
      active: row['active'] as bool,
    );
  });

  // ── Timetable ─────────────────────────────────────────────────────────────

  @override
  Future<List<PatternSummary>> patterns(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT p.id, p.route_id, r.code AS route_code, p.rrule,
                   to_char(p.departure_time, 'HH24:MI') AS departure_time,
                   p.fare_minor, p.currency::text AS currency, p.valid_from,
                   p.valid_until, p.active, p.default_vehicle_id
              FROM departure_patterns p
              JOIN routes r ON r.id = p.route_id
             WHERE p.operator_id = @operator
             ORDER BY r.code, p.departure_time
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return [
          for (final row in rows)
            if (Recurrence.parse(row.toColumnMap()['rrule'] as String)
                case Ok(value: final recurrence))
              PatternSummary(
                id: row.toColumnMap()['id'].toString(),
                routeId: row.toColumnMap()['route_id'].toString(),
                routeCode: row.toColumnMap()['route_code'] as String,
                recurrence: recurrence,
                departureTime: row.toColumnMap()['departure_time'] as String,
                fare: Money(
                  row.toColumnMap()['fare_minor'] as int,
                  Currency.byCode(
                    (row.toColumnMap()['currency'] as String).trim(),
                  )!,
                ),
                validFrom: row.toColumnMap()['valid_from'] as DateTime,
                validUntil: row.toColumnMap()['valid_until'] as DateTime?,
                active: row.toColumnMap()['active'] as bool,
                vehicleId:
                    row.toColumnMap()['default_vehicle_id']?.toString(),
              ),
        ];
      });

  @override
  Future<PatternSummary?> savePattern({
    required String operatorId,
    required String routeId,
    required Recurrence recurrence,
    required String departureTime,
    required Money fare,
    required DateTime validFrom,
    String? id,
    String? vehicleId,
    DateTime? validUntil,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO departure_patterns
          (id, operator_id, route_id, rrule, departure_time,
           default_vehicle_id, fare_minor, currency, valid_from, valid_until)
        VALUES (COALESCE(@id, gen_random_uuid()), @operator, @route, @rrule,
                @time::time, @vehicle, @fare, @currency, @from, @until)
        ON CONFLICT (id) DO UPDATE
           SET rrule = EXCLUDED.rrule,
               departure_time = EXCLUDED.departure_time,
               default_vehicle_id = EXCLUDED.default_vehicle_id,
               fare_minor = EXCLUDED.fare_minor,
               valid_from = EXCLUDED.valid_from,
               valid_until = EXCLUDED.valid_until
        RETURNING id, active
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, id),
        'operator': TypedValue(Type.uuid, operatorId),
        'route': TypedValue(Type.uuid, routeId),
        // Stored canonically, so what comes back out parses to what went in
        // and a hand-edited row cannot smuggle in a part we do not honour.
        'rrule': TypedValue(Type.text, recurrence.toRRule()),
        'time': TypedValue(Type.text, departureTime),
        'vehicle': TypedValue(Type.uuid, vehicleId),
        'fare': TypedValue(Type.bigInteger, fare.minor),
        'currency': TypedValue(Type.text, fare.currency.code),
        'from': TypedValue(Type.date, validFrom),
        'until': TypedValue(Type.date, validUntil),
      },
    );

    // Built from RETURNING rather than by re-reading through `patterns()`.
    // That call opens its own transaction on its own pooled connection, so
    // from inside this one it cannot see the row that has not committed yet —
    // and returned null every time, which is exactly what the integration
    // suite caught.
    final row = rows.first.toColumnMap();

    final code = await tx.execute(
      Sql.named('SELECT code FROM routes WHERE id = @route'),
      parameters: {'route': TypedValue(Type.uuid, routeId)},
    );
    if (code.isEmpty) return null;

    return PatternSummary(
      id: row['id'].toString(),
      routeId: routeId,
      routeCode: code.first.toColumnMap()['code'] as String,
      recurrence: recurrence,
      departureTime: departureTime,
      fare: fare,
      validFrom: validFrom,
      validUntil: validUntil,
      active: row['active'] as bool,
      vehicleId: vehicleId,
    );
  });

  @override
  Future<MaterialisationReport> materialise({
    required String operatorId,
    required String patternId,
    required DateTime from,
    required DateTime to,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final patternRows = await tx.execute(
      Sql.named('''
        SELECT p.route_id, p.rrule,
               to_char(p.departure_time, 'HH24:MI') AS departure_time,
               p.fare_minor, p.currency::text AS currency, p.valid_from,
               p.valid_until, p.active, p.default_vehicle_id,
               r.duration_minutes,
               v.seat_layout_id, v.status AS vehicle_status,
               v.amenities, v.mode,
               l.sections, l.blocked, l.capacity
          FROM departure_patterns p
          JOIN routes r ON r.id = p.route_id
          LEFT JOIN vehicles v ON v.id = p.default_vehicle_id
          LEFT JOIN seat_layouts l ON l.id = v.seat_layout_id
         WHERE p.id = @pattern AND p.operator_id = @operator
      '''),
      parameters: {
        'pattern': TypedValue(Type.uuid, patternId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    if (patternRows.isEmpty) {
      return const MaterialisationReport(
        created: 0,
        alreadyExisted: 0,
        skipped: [],
      );
    }

    final p = patternRows.first.toColumnMap();
    final skipped = <({DateTime date, String reason})>[];

    final recurrence = Recurrence.parse(p['rrule'] as String).valueOrNull;
    if (recurrence == null) {
      // A rule that no longer parses means the subset changed under a stored
      // row. Refusing the whole run rather than materialising a guess: the
      // guess is a coach on a road nobody scheduled.
      return MaterialisationReport(
        created: 0,
        alreadyExisted: 0,
        skipped: [(date: from, reason: 'unparseable_rrule')],
      );
    }

    if (p['active'] != true) {
      return MaterialisationReport(
        created: 0,
        alreadyExisted: 0,
        skipped: [(date: from, reason: 'pattern_inactive')],
      );
    }

    // Clamped to the pattern's own validity. A dispatcher asking for a year
    // of a timetable that ends in March should get three months, not an
    // error and not twelve.
    final validFrom = p['valid_from'] as DateTime;
    final validUntil = p['valid_until'] as DateTime?;
    final start = from.isBefore(validFrom) ? validFrom : from;
    final end = validUntil != null && validUntil.isBefore(to) ? validUntil : to;

    final dates = start.isAfter(end)
        ? const <DateTime>[]
        : recurrence.datesBetween(start, end, anchor: validFrom);

    final vehicleId = p['default_vehicle_id']?.toString();
    final layoutId = p['seat_layout_id']?.toString();

    if (vehicleId == null || layoutId == null) {
      // Named, not dropped. A silently missing Thursday is a coach nobody can
      // book and an operator who thinks they are selling it.
      return MaterialisationReport(
        created: 0,
        alreadyExisted: 0,
        skipped: [
          for (final date in dates) (date: date, reason: 'no_vehicle_assigned'),
        ],
      );
    }

    if (p['vehicle_status'] != 'active') {
      return MaterialisationReport(
        created: 0,
        alreadyExisted: 0,
        skipped: [
          for (final date in dates)
            (date: date, reason: 'vehicle_${p['vehicle_status']}'),
        ],
      );
    }

    final layout = _decodeLayout(p);
    final baseFare = Money(
      p['fare_minor'] as int,
      Currency.byCode((p['currency'] as String).trim())!,
    );
    final time = p['departure_time'] as String;
    final duration = p['duration_minutes'] as int;

    var created = 0;
    var existed = 0;

    for (final date in dates) {
      // The instant is built by POSTGRES from a local date and a local time
      // in the market's zone. Computing it in Dart would need this process to
      // know Africa/Brazzaville's rules, and would put the 06:00 an hour out
      // the day they ever change.
      final inserted = await tx.execute(
        Sql.named('''
          INSERT INTO departures
            (operator_id, route_id, pattern_id, vehicle_id, seat_layout_id,
             departs_at, arrives_at, capacity, fare_minor, currency,
             mode, amenities)
          SELECT @operator, @route, @pattern, @vehicle, @layout,
                 ts, ts + make_interval(mins => @duration),
                 @capacity, @fare, @currency, @mode, @amenities
            FROM (SELECT ((@date::date + @time::time) AT TIME ZONE @tz) AS ts) t
           WHERE NOT EXISTS (
                   SELECT 1 FROM departures d
                    WHERE d.pattern_id = @pattern
                      AND d.departs_at = ((@date::date + @time::time)
                                            AT TIME ZONE @tz)
                 )
          RETURNING id
        '''),
        parameters: {
          'operator': TypedValue(Type.uuid, operatorId),
          'route': TypedValue(Type.uuid, p['route_id'].toString()),
          'pattern': TypedValue(Type.uuid, patternId),
          'vehicle': TypedValue(Type.uuid, vehicleId),
          'layout': TypedValue(Type.uuid, layoutId),
          'date': TypedValue(Type.date, date),
          'time': TypedValue(Type.text, time),
          'tz': TypedValue(Type.text, timeZone),
          'duration': TypedValue(Type.integer, duration),
          'capacity': TypedValue(Type.integer, layout.capacity),
          'fare': TypedValue(Type.bigInteger, baseFare.minor),
          'currency': TypedValue(Type.text, baseFare.currency.code),
          'mode': TypedValue(Type.text, p['mode'] as String? ?? 'bus'),
          'amenities': TypedValue(
            Type.textArray,
            [for (final a in (p['amenities'] as List?) ?? const []) '$a'],
          ),
        },
      );

      // `WHERE NOT EXISTS` on (pattern, instant) is what makes re-running a
      // no-op. A dispatcher who taps twice must not put two coaches on one
      // road, and reporting the second run honestly beats silently doing
      // nothing.
      if (inserted.isEmpty) {
        existed++;
        continue;
      }

      final departureId = inserted.first.toColumnMap()['id'].toString();
      await _createSeats(tx, departureId, operatorId, layout, baseFare);
      created++;
    }

    return MaterialisationReport(
      created: created,
      alreadyExisted: existed,
      skipped: skipped,
    );
  });

  /// One seat row per sellable seat. This is what holds lock against
  /// (ADR-0012), so a departure without them is a departure nobody can book.
  Future<void> _createSeats(
    TxSession tx,
    String departureId,
    String operatorId,
    SeatLayout layout,
    Money baseFare,
  ) async {
    for (final label in layout.allSeatLabels()) {
      if (layout.blocked.contains(label)) continue;

      final section = layout.sectionForSeat(label);
      // Priced by the LAYOUT, not by a special case in the sales path — which
      // is what lets the same code sell a 2+2 coach and a two-class cabin.
      final fare = layout.fareFor(label, baseFare);

      await tx.execute(
        Sql.named('''
          INSERT INTO seats (departure_id, seat_label, operator_id,
                             section_code, fare_minor, currency)
          VALUES (@departure, @label, @operator, @section, @fare, @currency)
          ON CONFLICT (departure_id, seat_label) DO NOTHING
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'label': TypedValue(Type.text, label),
          'operator': TypedValue(Type.uuid, operatorId),
          'section': TypedValue(Type.text, section?.code ?? 'STD'),
          'fare': TypedValue(Type.bigInteger, fare.minor),
          'currency': TypedValue(Type.text, fare.currency.code),
        },
        ignoreRows: true,
      );
    }
  }

  // ── Operations ────────────────────────────────────────────────────────────

  @override
  Future<List<DepartureBoardRow>> board({
    required String operatorId,
    required DateTime localDate,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT d.id, d.departs_at, d.status::text AS status, d.capacity,
               r.code AS route_code, v.registration,
               count(*) FILTER (WHERE s.state = 'sold')::int AS sold,
               count(*) FILTER (WHERE s.state = 'held')::int AS held
          FROM departures d
          JOIN routes r ON r.id = d.route_id
          LEFT JOIN vehicles v ON v.id = d.vehicle_id
          LEFT JOIN seats s ON s.departure_id = d.id
         WHERE d.operator_id = @operator
           AND (d.departs_at AT TIME ZONE @tz)::date = @date::date
         GROUP BY d.id, r.code, v.registration
         ORDER BY d.departs_at
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'date': TypedValue(Type.date, localDate),
        'tz': TypedValue(Type.text, timeZone),
      },
    );

    return [
      for (final row in rows)
        DepartureBoardRow(
          id: row.toColumnMap()['id'].toString(),
          routeCode: row.toColumnMap()['route_code'] as String,
          departsAt: row.toColumnMap()['departs_at'] as DateTime,
          status: row.toColumnMap()['status'] as String,
          capacity: row.toColumnMap()['capacity'] as int,
          sold: row.toColumnMap()['sold'] as int,
          held: row.toColumnMap()['held'] as int,
          vehicleRegistration: row.toColumnMap()['registration'] as String?,
        ),
    ];
  });

  @override
  Future<Manifest?> manifest({
    required String operatorId,
    required String departureId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final header = await tx.execute(
      Sql.named('''
        SELECT d.departs_at, d.capacity, r.code AS route_code
          FROM departures d
          JOIN routes r ON r.id = d.route_id
         WHERE d.id = @id AND d.operator_id = @operator
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    if (header.isEmpty) return null;

    // Only CONFIRMED bookings. A reservation somebody has not paid for is not
    // a passenger, and putting one on a manifest is how a conductor ends up
    // arguing with somebody holding a phone at the roadside.
    final rows = await tx.execute(
      Sql.named('''
        SELECT bs.seat_label, bs.passenger_name, bs.passenger_phone,
               b.ref, red.scanned_at
          FROM bookings b
          JOIN booking_seats bs ON bs.booking_id = b.id
          LEFT JOIN tickets t
                 ON t.booking_id = b.id AND t.seat_label = bs.seat_label
          LEFT JOIN redemptions red ON red.ticket_id = t.id
         WHERE b.departure_id = @id
           AND b.operator_id = @operator
           AND b.state = 'confirmed'
           AND t.voided_at IS NULL
         ORDER BY bs.seat_label
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    final head = header.first.toColumnMap();
    return Manifest(
      departureId: departureId,
      routeCode: head['route_code'] as String,
      departsAt: head['departs_at'] as DateTime,
      capacity: head['capacity'] as int,
      rows: [
        for (final row in rows)
          ManifestRow(
            seatLabel: row.toColumnMap()['seat_label'] as String,
            passengerName: row.toColumnMap()['passenger_name'] as String,
            passengerPhone: row.toColumnMap()['passenger_phone'] as String?,
            bookingRef: row.toColumnMap()['ref'] as String,
            boarded: row.toColumnMap()['scanned_at'] != null,
            boardedAt: row.toColumnMap()['scanned_at'] as DateTime?,
          ),
      ],
    );
  });

  // ── Encoding ──────────────────────────────────────────────────────────────

  static VehicleSummary _vehicle(Map<String, dynamic> r) => VehicleSummary(
    id: r['id'].toString(),
    registration: r['registration'] as String,
    layoutId: r['seat_layout_id'].toString(),
    layoutName: r['layout_name'] as String,
    capacity: r['capacity'] as int,
    status: r['status'] as String,
    nickname: r['nickname'] as String?,
    model: r['model'] as String?,
    amenities: [for (final a in (r['amenities'] as List?) ?? const []) '$a'],
  );

  static List<Map<String, Object?>> _sections(SeatLayout layout) => [
    for (final s in layout.sections)
      {
        'code': s.code,
        'labelKey': s.labelKey,
        'rows': s.rows,
        'abreast': s.abreast,
        'startRow': s.startRow,
        'numbering': s.numbering.name,
        'pitchCm': s.pitchCm,
        'modifier': switch (s.modifier) {
          MultiplierModifier(:final value) => {
            'kind': 'multiplier',
            'value': value,
          },
          SupplementModifier(:final minor) => {
            'kind': 'supplement',
            'minor': minor,
          },
          null => null,
        },
      },
  ];

  static List<Map<String, Object?>> _features(SeatLayout layout) => [
    for (final f in layout.features)
      {'type': f.type.name, 'row': f.row, 'col': f.col},
  ];

  static SeatLayout _decodeLayout(Map<String, dynamic> p) {
    final raw = p['sections'];
    final decoded = raw is String ? jsonDecode(raw) : raw;
    final sections = <CabinSection>[];

    for (final entry in (decoded as List? ?? const [])) {
      final s = (entry as Map).cast<String, Object?>();
      sections.add(
        CabinSection(
          code: s['code'] as String? ?? 'STD',
          labelKey: s['labelKey'] as String? ?? 'seat.class.standard',
          rows: s['rows'] as int? ?? 0,
          abreast: s['abreast'] as String? ?? '2+2',
          startRow: s['startRow'] as int? ?? 1,
          numbering: SeatNumbering.values.firstWhere(
            (n) => n.name == s['numbering'],
            orElse: () => SeatNumbering.rowLetter,
          ),
          pitchCm: s['pitchCm'] as int?,
          modifier: switch ((s['modifier'] as Map?)?.cast<String, Object?>()) {
            {'kind': 'multiplier', 'value': final num v} =>
              PriceModifier.multiplier(v.toDouble()),
            {'kind': 'supplement', 'minor': final int m} =>
              PriceModifier.supplementMinor(m),
            _ => null,
          },
        ),
      );
    }

    return SeatLayout(
      version: 1,
      mode: TransportMode.values.firstWhere(
        (m) => m.name == p['mode'],
        orElse: () => TransportMode.bus,
      ),
      sections: sections,
      blocked: {for (final b in (p['blocked'] as List?) ?? const []) '$b'},
    );
  }
}
