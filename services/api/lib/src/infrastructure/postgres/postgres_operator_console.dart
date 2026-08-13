import 'dart:convert';
import 'dart:math';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
// The domain's `quoteRefund` is the one function both the app and the server
// call (ADR-0004), and this class has a method of the same name that fetches
// the booking first. The prefix keeps the two apart in the one place where
// the shadowing would silently pick the wrong one.
import 'package:bel_domain/bel_domain.dart' as domain;
import 'package:postgres/postgres.dart';

import '../../application/ports/operator_console.dart';
import '../db/database.dart';
import 'refund_wallet.dart';
import 'seat_occupancy.dart';

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
  Future<List<RouteSummary>> routes(String operatorId) => _db.transaction(
    DbScope.tenant(operatorId),
    (tx) async {
      final rows = await tx.execute(
        Sql.named('''
            SELECT id, code, origin_city, destination_city, duration_minutes,
                   active
              FROM routes WHERE operator_id = @operator ORDER BY code
          '''),
        parameters: {'operator': TypedValue(Type.uuid, operatorId)},
      );

      if (rows.isEmpty) return const [];

      // One query for every road's stops rather than one per road. A
      // company with thirty routes is a company whose console would
      // otherwise open with thirty round trips.
      final ids = [for (final row in rows) row.toColumnMap()['id'].toString()];
      final stops = await _stopsFor(tx, ids);
      final priced = await _segmentsFor(tx, ids);

      return [
        for (final row in rows)
          () {
            final map = row.toColumnMap();
            final id = map['id'].toString();
            final found = stops[id] ?? const <_Stop>[];
            return RouteSummary(
              id: id,
              code: map['code'] as String,
              originCity: map['origin_city'] as String,
              destinationCity: map['destination_city'] as String,
              durationMinutes: map['duration_minutes'] as int,
              active: map['active'] as bool,
              stops: [for (final s in found) s.stop],
              stopStationNames: {
                for (final s in found)
                  if (s.stop.stationId != null && s.stationName != null)
                    s.stop.stationId!: s.stationName!,
              },
              segments: priced[id] ?? SegmentPricing.empty,
            );
          }(),
      ];
    },
  );

  /// The stops of several roads at once, in order, with their yards' names.
  Future<Map<String, List<_Stop>>> _stopsFor(
    TxSession tx,
    List<String> routeIds,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT rs.route_id, rs.city_code, rs.offset_minutes, rs.station_id,
               rs.allows_boarding, rs.allows_alighting, st.name AS station_name
          FROM route_stops rs
          LEFT JOIN stations st ON st.id = rs.station_id
         WHERE rs.route_id = ANY(@ids::uuid[])
         ORDER BY rs.route_id, rs.sequence
      '''),
      parameters: {'ids': TypedValue(Type.textArray, routeIds)},
    );

    final byRoute = <String, List<_Stop>>{};
    for (final row in rows) {
      final map = row.toColumnMap();
      byRoute
          .putIfAbsent(map['route_id'].toString(), () => [])
          .add(
            _Stop(
              stop: RouteStop(
                cityCode: map['city_code'] as String,
                offsetMinutes: map['offset_minutes'] as int,
                stationId: map['station_id']?.toString(),
                allowsBoarding: map['allows_boarding'] as bool,
                allowsAlighting: map['allows_alighting'] as bool,
              ),
              stationName: map['station_name'] as String?,
            ),
          );
    }
    return byRoute;
  }

  @override
  Future<RouteSummary?> saveRoute({
    required String operatorId,
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    int? distanceKm,
    Itinerary? stops,
    SegmentPricing? segments,
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
    final routeId = row['id'].toString();

    // Replaced wholesale, in the same transaction as the road itself. A route
    // form is a whole description of a road: merging would leave a stop the
    // operator deleted still standing on the timetable, and a delete-then-
    // insert in two transactions is a moment when the road has no stops at
    // all while somebody is reading it.
    if (stops != null) {
      await tx.execute(
        Sql.named('DELETE FROM route_stops WHERE route_id = @route'),
        parameters: {'route': TypedValue(Type.uuid, routeId)},
        ignoreRows: true,
      );

      var sequence = 0;
      for (final stop in stops.stops) {
        sequence++;
        await tx.execute(
          Sql.named('''
            INSERT INTO route_stops
              (route_id, city_code, station_id, sequence, offset_minutes,
               allows_boarding, allows_alighting)
            VALUES (@route, @city, @station, @sequence, @offset,
                    @boarding, @alighting)
          '''),
          parameters: {
            'route': TypedValue(Type.uuid, routeId),
            'city': TypedValue(Type.text, stop.cityCode),
            'station': TypedValue(Type.uuid, stop.stationId),
            // Assigned here, never accepted from a client: the sequence is
            // what a segment will be a pair of indices into, and a list that
            // numbers itself is a list that can be numbered wrong.
            'sequence': TypedValue(Type.integer, sequence),
            'offset': TypedValue(Type.integer, stop.offsetMinutes),
            'boarding': TypedValue(Type.boolean, stop.allowsBoarding),
            'alighting': TypedValue(Type.boolean, stop.allowsAlighting),
          },
          ignoreRows: true,
        );
      }
    }

    // Replaced wholesale, in the same transaction as the road it prices, and
    // for the same reason the stops are: a route form is a whole description
    // of a road, so an empty list is how the last price is withdrawn. Omitted
    // entirely leaves the list alone, so a caller saving a duration cannot
    // take a road off sale by not mentioning it.
    if (segments != null) {
      await tx.execute(
        Sql.named('DELETE FROM segment_fares WHERE route_id = @route'),
        parameters: {'route': TypedValue(Type.uuid, routeId)},
        ignoreRows: true,
      );

      for (final price in segments.prices) {
        await tx.execute(
          Sql.named('''
            INSERT INTO segment_fares
              (operator_id, route_id, from_position, to_position,
               fare_minor, currency)
            VALUES (@operator, @route, @from, @to, @minor, @currency)
          '''),
          parameters: {
            'operator': TypedValue(Type.uuid, operatorId),
            'route': TypedValue(Type.uuid, routeId),
            // Positions, not city codes: a road that visits the same town
            // twice is unusual and not impossible, and a pair of codes
            // cannot say which visit was meant (ADR-0025).
            'from': TypedValue(Type.integer, price.segment.from),
            'to': TypedValue(Type.integer, price.segment.to),
            'minor': TypedValue(Type.bigInteger, price.fare.minor),
            'currency': TypedValue(Type.text, price.fare.currency.code),
          },
          ignoreRows: true,
        );
      }
    }

    final saved = await _stopsFor(tx, [routeId]);
    final found = saved[routeId] ?? const <_Stop>[];
    final priced = await _segmentsFor(tx, [routeId]);

    return RouteSummary(
      id: routeId,
      code: row['code'] as String,
      originCity: row['origin_city'] as String,
      destinationCity: row['destination_city'] as String,
      durationMinutes: row['duration_minutes'] as int,
      active: row['active'] as bool,
      stops: [for (final s in found) s.stop],
      stopStationNames: {
        for (final s in found)
          if (s.stop.stationId != null && s.stationName != null)
            s.stop.stationId!: s.stationName!,
      },
      segments: priced[routeId] ?? SegmentPricing.empty,
    );
  });

  /// What several roads have been priced at, in one query. Same reasoning as
  /// [_stopsFor]: a company with thirty routes is a company whose console
  /// would otherwise open with thirty round trips.
  Future<Map<String, SegmentPricing>> _segmentsFor(
    TxSession tx,
    List<String> routeIds,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT route_id, from_position, to_position, fare_minor, currency
          FROM segment_fares
         WHERE route_id = ANY(@ids::uuid[]) AND active
         ORDER BY route_id, from_position, to_position
      '''),
      parameters: {'ids': TypedValue(Type.textArray, routeIds)},
    );

    final byRoute = <String, List<SegmentPrice>>{};
    for (final row in rows) {
      final map = row.toColumnMap();
      byRoute
          .putIfAbsent(map['route_id'].toString(), () => [])
          .add(
            SegmentPrice(
              segment: Segment.at(
                map['from_position'] as int,
                map['to_position'] as int,
              ),
              fare: Money(
                map['fare_minor'] as int,
                Currency.byCode((map['currency'] as String).trim())!,
              ),
            ),
          );
    }

    // Read back rather than re-validated: these rows were checked against the
    // road when they were written, and a price list that refused to load
    // because somebody later moved a stop would take a road off sale without
    // anybody deciding to.
    return {
      for (final entry in byRoute.entries)
        entry.key: SegmentPricing.fromRows(entry.value),
    };
  }

  // ── Stations ──────────────────────────────────────────────────────────────

  static const _stationColumns = '''
    id, city_code, name, lat, lng, boarding_notes, active
  ''';

  static StationSummary _stationFrom(Map<String, dynamic> row) =>
      StationSummary(
        id: row['id'].toString(),
        cityCode: row['city_code'] as String,
        name: row['name'] as String,
        active: row['active'] as bool,
        lat: row['lat'] as double?,
        lng: row['lng'] as double?,
        boardingNotes: row['boarding_notes'] as String?,
      );

  @override
  Future<List<StationSummary>> stations(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT $_stationColumns FROM stations
             WHERE operator_id = @operator
             ORDER BY city_code, active DESC, name
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );
        return [for (final row in rows) _stationFrom(row.toColumnMap())];
      });

  @override
  Future<StationSummary?> saveStation({
    required String operatorId,
    required String cityCode,
    required String name,
    String? id,
    double? lat,
    double? lng,
    String? boardingNotes,
    bool active = true,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Keyed on `(operator, city, name)` rather than on the id, so an agency
    // that types the same yard in twice gets one row and its own edit —
    // which is what the unique constraint would otherwise turn into a 500.
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO stations
          (id, operator_id, city_code, name, lat, lng, boarding_notes, active)
        VALUES (COALESCE(@id, gen_random_uuid()), @operator, @city, @name,
                @lat, @lng, @notes, @active)
        ON CONFLICT (operator_id, city_code, name) DO UPDATE
           SET lat = EXCLUDED.lat,
               lng = EXCLUDED.lng,
               boarding_notes = EXCLUDED.boarding_notes,
               active = EXCLUDED.active
        RETURNING $_stationColumns
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, id),
        'operator': TypedValue(Type.uuid, operatorId),
        'city': TypedValue(Type.text, cityCode),
        'name': TypedValue(Type.text, name),
        'lat': TypedValue(Type.double, lat),
        'lng': TypedValue(Type.double, lng),
        'notes': TypedValue(Type.text, boardingNotes),
        'active': TypedValue(Type.boolean, active),
      },
    );

    return _stationFrom(rows.first.toColumnMap());
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
            if (Recurrence.parse(row.toColumnMap()['rrule'] as String) case Ok(
              value: final recurrence,
            ))
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
                vehicleId: row.toColumnMap()['default_vehicle_id']?.toString(),
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
    String? originStationId,
    String? destinationStationId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO departure_patterns
          (id, operator_id, route_id, rrule, departure_time,
           default_vehicle_id, fare_minor, currency, valid_from, valid_until,
           origin_station_id, destination_station_id)
        VALUES (COALESCE(@id, gen_random_uuid()), @operator, @route, @rrule,
                @time::time, @vehicle, @fare, @currency, @from, @until,
                @originStation, @destinationStation)
        ON CONFLICT (id) DO UPDATE
           SET rrule = EXCLUDED.rrule,
               departure_time = EXCLUDED.departure_time,
               default_vehicle_id = EXCLUDED.default_vehicle_id,
               fare_minor = EXCLUDED.fare_minor,
               valid_from = EXCLUDED.valid_from,
               valid_until = EXCLUDED.valid_until,
               origin_station_id = EXCLUDED.origin_station_id,
               destination_station_id = EXCLUDED.destination_station_id
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
        // The composite foreign key refuses another operator's yard, so a
        // mistyped id is a 500 rather than a ticket sent to a rival's gate.
        'originStation': TypedValue(Type.uuid, originStationId),
        'destinationStation': TypedValue(Type.uuid, destinationStationId),
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
               p.origin_station_id, p.destination_station_id,
               r.duration_minutes,
               v.seat_layout_id, v.status AS vehicle_status,
               v.amenities, v.mode,
               l.sections, l.features, l.blocked, l.capacity
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

    final layout = decodeLayout(p);
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
             mode, amenities, origin_station_id, destination_station_id,
             road_span)
          SELECT @operator, @route, @pattern, @vehicle, @layout,
                 ts, ts + make_interval(mins => @duration),
                 @capacity, @fare, @currency, @mode, @amenities,
                 @originStation, @destinationStation,
                 -- The road this coach is put on sale with, numbered here and
                 -- never again (ADR-0025). Origin is 0, each stop follows in
                 -- sequence, the destination is the exclusive upper bound —
                 -- so a road with no intermediate stops is `[0,1)`, which is
                 -- every departure that existed before segments.
                 --
                 -- Captured rather than joined, because a stop added next
                 -- month must not renumber what was sold this month: a
                 -- passenger who bought positions 1→2 bought Dolisie to
                 -- Pointe-Noire, and it has to stay that journey.
                 int4range(0, 1 + (SELECT count(*)::int FROM route_stops rs
                                    WHERE rs.route_id = @route))
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
          'amenities': TypedValue(Type.textArray, [
            for (final a in (p['amenities'] as List?) ?? const []) '$a',
          ]),
          // Copied onto the departure rather than read through the pattern
          // whenever anybody asks, for the same reason the seat layout is:
          // renaming or closing a terminal next month must not rewrite where
          // a coach that is already sold was said to leave from.
          'originStation': TypedValue(
            Type.uuid,
            p['origin_station_id']?.toString(),
          ),
          'destinationStation': TypedValue(
            Type.uuid,
            p['destination_station_id']?.toString(),
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
        WITH road AS (
          SELECT r.id AS route_id, 0 AS position, r.origin_city AS city
            FROM routes r
           UNION ALL
          SELECT rs.route_id, rs.sequence, rs.city_code FROM route_stops rs
           UNION ALL
          SELECT r.id,
                 1 + (SELECT count(*)::int FROM route_stops x
                       WHERE x.route_id = r.id),
                 r.destination_city
            FROM routes r
        )
        SELECT bs.seat_label, bs.passenger_name, bs.passenger_phone,
               b.ref, red.scanned_at,
               -- Where this passenger gets on and off, and only when that
               -- is a piece of the road rather than the whole of it
               -- (ADR-0025). The header already names the road, so repeating
               -- it on every row would bury the one line that matters: the
               -- conductor's list is the one place somebody finds out that
               -- 12A comes free at Dolisie.
               CASE WHEN b.road_span <> d.road_span THEN fs.city END
                 AS boards_at,
               CASE WHEN b.road_span <> d.road_span THEN ts.city END
                 AS alights_at
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          JOIN booking_seats bs ON bs.booking_id = b.id
          LEFT JOIN tickets t
                 ON t.booking_id = b.id AND t.seat_label = bs.seat_label
          LEFT JOIN redemptions red ON red.ticket_id = t.id
          LEFT JOIN road fs ON fs.route_id = d.route_id
                           AND fs.position = lower(b.road_span)
          LEFT JOIN road ts ON ts.route_id = d.route_id
                           AND ts.position = upper(b.road_span)
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
            boardsAt: row.toColumnMap()['boards_at'] as String?,
            alightsAt: row.toColumnMap()['alights_at'] as String?,
          ),
      ],
    );
  });

  @override
  Future<List<BoardingDeparture>> boardingDay({
    required String operatorId,
    required DateTime localDate,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // A LOCAL calendar day, like the dispatcher's board: "coaches on the 15th"
    // is a local question, and a UTC comparison puts the 06:00 on the wrong
    // day. The zone is the market's, applied by Postgres — Dart has no zone
    // database and this is the one place a one-hour error strands somebody.
    final rows = await tx.execute(
      Sql.named('''
        SELECT d.id, d.departs_at, d.capacity, d.status::text AS status,
               r.code AS route_code, r.origin_city, r.destination_city,
               s.name AS station_name,
               (SELECT count(*)::int FROM tickets t
                 WHERE t.departure_id = d.id AND t.voided_at IS NULL)
                 AS expected
          FROM departures d
          JOIN routes r ON r.id = d.route_id
          LEFT JOIN stations s ON s.id = d.origin_station_id
         WHERE d.operator_id = @operator
           AND (d.departs_at AT TIME ZONE @tz)::date = @day::date
         ORDER BY d.departs_at
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'day': TypedValue(Type.date, localDate),
        'tz': TypedValue(Type.text, timeZone),
      },
    );

    return [
      for (final row in rows)
        () {
          final r = row.toColumnMap();
          return BoardingDeparture(
            id: r['id'].toString(),
            routeCode: r['route_code']! as String,
            originCity: r['origin_city']! as String,
            destinationCity: r['destination_city']! as String,
            departsAt: r['departs_at']! as DateTime,
            expected: r['expected']! as int,
            capacity: r['capacity']! as int,
            stationName: r['station_name'] as String?,
            status: r['status']! as String,
          );
        }(),
    ];
  });

  @override
  Future<BoardingManifestData?> boardingManifest({
    required String operatorId,
    required String departureId,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final header = await tx.execute(
      Sql.named('''
        SELECT d.departs_at, d.capacity, r.code AS route_code,
               o.code AS operator_code
          FROM departures d
          JOIN routes r ON r.id = d.route_id
          JOIN operators o ON o.id = d.operator_id
         WHERE d.id = @id AND d.operator_id = @operator
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );
    if (header.isEmpty) return null;

    // Tickets rather than bookings, because a ticket is what gets scanned:
    // one row per seat, carrying its own secret, and a voided one is still a
    // row — the device has to be told about it rather than left to infer it
    // from an absence.
    final rows = await tx.execute(
      Sql.named('''
        WITH road AS (
          SELECT r.id AS route_id, 0 AS position, r.origin_city AS city
            FROM routes r
           UNION ALL
          SELECT rs.route_id, rs.sequence, rs.city_code FROM route_stops rs
           UNION ALL
          SELECT r.id,
                 1 + (SELECT count(*)::int FROM route_stops x
                       WHERE x.route_id = r.id),
                 r.destination_city
            FROM routes r
        )
        SELECT b.ref, t.seat_label, bs.passenger_name, t.rotating_secret,
               t.voided_at,
               CASE WHEN b.road_span <> d.road_span THEN fs.city END
                 AS boards_at,
               CASE WHEN b.road_span <> d.road_span THEN ts.city END
                 AS alights_at
          FROM tickets t
          JOIN bookings b ON b.id = t.booking_id
          JOIN departures d ON d.id = b.departure_id
          JOIN booking_seats bs
            ON bs.booking_id = b.id AND bs.seat_label = t.seat_label
          LEFT JOIN road fs ON fs.route_id = d.route_id
                           AND fs.position = lower(b.road_span)
          LEFT JOIN road ts ON ts.route_id = d.route_id
                           AND ts.position = upper(b.road_span)
         WHERE b.departure_id = @id
           AND b.operator_id = @operator
         ORDER BY t.seat_label
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, departureId),
        'operator': TypedValue(Type.uuid, operatorId),
      },
    );

    final head = header.first.toColumnMap();
    final live = <BoardingTicket>[];
    final voided = <String>[];

    for (final row in rows) {
      final r = row.toColumnMap();
      final ref = r['ref'] as String;
      final seat = r['seat_label'] as String;
      if (r['voided_at'] != null) {
        voided.add('$ref/$seat');
        continue;
      }
      live.add(
        BoardingTicket(
          bookingRef: ref,
          seatLabel: seat,
          passengerName: r['passenger_name'] as String,
          rotatingSecret: (r['rotating_secret'] as List).cast<int>(),
          boardsAt: r['boards_at'] as String?,
          alightsAt: r['alights_at'] as String?,
        ),
      );
    }

    return BoardingManifestData(
      departureId: departureId,
      operatorCode: head['operator_code'] as String,
      routeCode: head['route_code'] as String,
      departsAt: head['departs_at'] as DateTime,
      capacity: head['capacity'] as int,
      tickets: live,
      voided: voided,
    );
  });

  @override
  Future<({List<String> recorded, List<String> unknown})> recordBoardings({
    required String operatorId,
    required String departureId,
    required String? scannedByUserId,
    required List<Boarding> boardings,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final recorded = <String>[];
    final unknown = <String>[];

    for (final b in boardings) {
      // One statement resolves the ticket and writes the boarding, so a
      // reference that belongs to another coach cannot be recorded against
      // this one by a device that got confused about which departure it was
      // pinned to. `DO NOTHING` is the first-scan-wins rule: a retry, or a
      // second door, must not overwrite the time somebody actually boarded.
      final done = await tx.execute(
        Sql.named('''
          INSERT INTO redemptions
            (ticket_id, departure_id, operator_id, scanned_at, device_id,
             scanned_by, mode, code_was_stale, synced_at)
          SELECT t.id, b.departure_id, b.operator_id, @at, @device,
                 @by, @mode::redemption_mode, @stale, now()
            FROM tickets t
            JOIN bookings b ON b.id = t.booking_id
           WHERE b.departure_id = @departure
             AND b.operator_id = @operator
             AND b.ref = @ref
             AND t.seat_label = @seat
             AND t.voided_at IS NULL
          ON CONFLICT (ticket_id) DO NOTHING
          RETURNING ticket_id
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'operator': TypedValue(Type.uuid, operatorId),
          'ref': TypedValue(Type.text, b.bookingRef),
          'seat': TypedValue(Type.text, b.seatLabel),
          'at': TypedValue(Type.timestampTz, b.scannedAt.toUtc()),
          'device': TypedValue(Type.text, b.deviceId),
          'by': TypedValue(Type.uuid, scannedByUserId),
          'mode': TypedValue(Type.text, b.mode),
          'stale': TypedValue(Type.boolean, b.codeWasStale),
        },
      );

      if (done.isNotEmpty) {
        recorded.add(b.key);
        continue;
      }

      // Nothing written: either it is already there — which is a success from
      // the device's point of view, and the whole reason a retry is safe — or
      // this coach has never heard of the ticket.
      final existing = await tx.execute(
        Sql.named('''
          SELECT 1
            FROM redemptions r
            JOIN tickets t ON t.id = r.ticket_id
            JOIN bookings b ON b.id = t.booking_id
           WHERE r.departure_id = @departure
             AND b.ref = @ref AND t.seat_label = @seat
        '''),
        parameters: {
          'departure': TypedValue(Type.uuid, departureId),
          'ref': TypedValue(Type.text, b.bookingRef),
          'seat': TypedValue(Type.text, b.seatLabel),
        },
      );

      (existing.isEmpty ? unknown : recorded).add(b.key);
    }

    return (recorded: recorded, unknown: unknown);
  });

  // ── Getting paid ──────────────────────────────────────────────────────────

  // ── Refunds ───────────────────────────────────────────────────────────────

  @override
  Future<RefundOffer?> quoteRefund({
    required String operatorId,
    required String bookingRef,
    required DateTime now,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final row = await _bookingForRefund(tx, bookingRef);
    return row == null ? null : _offer(row, now);
  });

  @override
  Future<IssuedRefund?> refundBooking({
    required String operatorId,
    required String bookingRef,
    required String actorUserId,
    required String reason,
    required DateTime now,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    final row = await _bookingForRefund(tx, bookingRef);
    if (row == null) return null;

    final offer = _offer(row, now);
    if (!offer.isRefundable) return null;

    final quote = offer.quote!;
    final bookingId = row['id'].toString();

    // Confirmed → refunded, conditionally. Two vendors refunding the same
    // booking at two windows of one agency is not hypothetical, and the
    // condition is what makes the second one a no-op rather than a second
    // payout.
    final moved = await tx.execute(
      Sql.named('''
        UPDATE bookings SET state = 'refunded'
         WHERE id = @id AND state = 'confirmed'
        RETURNING id
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
    );
    if (moved.isEmpty) return null;

    // Voided at approval, not at collection: a ticket whose money is already
    // owed back must not board while the cash is still in the drawer. The
    // schema comment on `voided_at` asks for exactly this.
    await tx.execute(
      Sql.named('''
        UPDATE tickets SET voided_at = now()
         WHERE booking_id = @id AND voided_at IS NULL
      '''),
      parameters: {'id': TypedValue(Type.uuid, bookingId)},
      ignoreRows: true,
    );

    // Back on sale in the same transaction. A seat left sold after a refund is
    // a seat nobody can buy and nobody is sitting in.
    await SeatOccupancy.releaseBooking(tx, bookingId);

    // Whose pocket it comes out of. The service fee is ours, and it only
    // moves when the operator's policy says it does.
    final fromServiceFee = offer.policy!.refundServiceFee
        ? offer.serviceFee
        : Money(0, quote.refundable.currency);
    final fromOperator = quote.refundable - fromServiceFee;
    if (fromOperator.minor < 0) return null;

    final posting = Postings.refundApproved(
      operatorId: operatorId,
      bookingId: bookingId,
      fromOperator: fromOperator,
      fromServiceFee: fromServiceFee,
    );
    if (posting.valueOrNull == null) return null;

    final destination = quote.destination;
    // `source` goes back down the rail it came up, and the worker sends it.
    // Where it goes is read **now** and copied onto the row: a traveller who
    // changes handsets on Thursday must not redirect Tuesday's approved
    // refund.
    final wallet = destination == RefundDestination.source
        ? await refundWalletFor(tx, bookingId)
        : null;

    // A claim is the counter path — and it is also the honest answer when
    // there is nowhere to send anything. A ticket bought with notes has no
    // wallet and a card has a PAN we have never seen, so a `source` policy
    // over one of those becomes a claim rather than a row nobody can pay.
    final wantsClaim =
        destination == RefundDestination.agencyCash ||
        destination == RefundDestination.travellerChoice ||
        (destination == RefundDestination.source && wallet == null);
    final claimCode = wantsClaim ? _claimCode() : null;

    final refund = await tx.execute(
      Sql.named('''
        INSERT INTO refunds
          (booking_id, operator_id, amount_minor, currency, rate_bps,
           destination, state, involuntary, claim_code, claim_expires_at,
           disburse_to, requested_by, approved_by, reason)
        VALUES (@booking, @operator, @amount, @currency, @rate, @destination,
                @state::refund_state, @involuntary, @claim,
                CASE WHEN @claim::text IS NULL THEN NULL
                     ELSE now() + interval '90 days' END,
                @wallet, @actor, @actor, @reason)
        RETURNING id, state::text AS state, claim_code, claim_expires_at
      '''),
      parameters: {
        'booking': TypedValue(Type.uuid, bookingId),
        'operator': TypedValue(Type.uuid, operatorId),
        'amount': TypedValue(Type.bigInteger, quote.refundable.minor),
        'currency': TypedValue(Type.text, quote.refundable.currency.code),
        'rate': TypedValue(Type.integer, quote.rateBps),
        // Named for where it actually goes. A row that says `source` and
        // carries a claim code is a row a support agent has to reconcile by
        // reading the state column, which is how the wrong sentence gets
        // read out to somebody at a counter.
        'destination': TypedValue(
          Type.text,
          wantsClaim && destination == RefundDestination.source
              ? RefundDestination.agencyCash.name
              : destination.name,
        ),
        'wallet': TypedValue(Type.text, wallet),
        'state': TypedValue(
          Type.text,
          wantsClaim ? 'claim_issued' : 'approved',
        ),
        'involuntary': TypedValue(Type.boolean, quote.involuntary),
        'claim': TypedValue(Type.text, claimCode),
        'actor': TypedValue(Type.uuid, actorUserId),
        'reason': TypedValue(Type.text, reason),
      },
    );

    final refundRow = refund.first.toColumnMap();
    await _postRefundLedger(
      tx,
      posting.valueOrNull!,
      operatorId: operatorId,
      bookingId: bookingId,
      refundId: refundRow['id'].toString(),
    );

    return IssuedRefund(
      id: refundRow['id'].toString(),
      bookingRef: row['ref'] as String,
      amount: quote.refundable,
      destination: destination.name,
      state: refundRow['state'] as String,
      claimCode: refundRow['claim_code'] as String?,
      claimExpiresAt: refundRow['claim_expires_at'] as DateTime?,
    );
  });

  @override
  Future<ClaimedRefund?> claimRefund({
    required String operatorId,
    required String claimCode,
    required String stationId,
    required String actorUserId,
    required DateTime now,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Read and close in one statement. Two vendors scanning the same code at
    // two counters is exactly the race a separate SELECT would lose, and the
    // thing it would lose is cash.
    final rows = await tx.execute(
      Sql.named('''
        UPDATE refunds
           SET state = 'claimed', claimed_by = @actor, completed_at = now()
         WHERE claim_code = @code
           AND state = 'claim_issued'
           AND (claim_expires_at IS NULL OR claim_expires_at > now())
        RETURNING id, booking_id, amount_minor, currency,
                  (SELECT ref FROM bookings b WHERE b.id = booking_id) AS ref
      '''),
      parameters: {
        'code': TypedValue(Type.text, claimCode.trim().toUpperCase()),
        'actor': TypedValue(Type.uuid, actorUserId),
      },
    );
    if (rows.isEmpty) return null;

    final row = rows.first.toColumnMap();
    final amount = Money(
      row['amount_minor'] as int,
      Currency.byCode((row['currency'] as String).trim())!,
    );

    final posting = Postings.refundPaidInCash(
      operatorId: operatorId,
      stationId: stationId,
      bookingId: row['booking_id'].toString(),
      amount: amount,
    );
    if (posting.valueOrNull == null) return null;

    await _postRefundLedger(
      tx,
      posting.valueOrNull!,
      operatorId: operatorId,
      bookingId: row['booking_id'].toString(),
      refundId: row['id'].toString(),
    );

    return ClaimedRefund(
      id: row['id'].toString(),
      bookingRef: row['ref'] as String,
      amount: amount,
      stationId: stationId,
    );
  });

  /// The booking, its money, and the policy version it was **sold under**.
  Future<Map<String, Object?>?> _bookingForRefund(
    TxSession tx,
    String bookingRef,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT b.id, b.ref, b.state::text AS state,
               b.fare_minor, b.service_fee_minor, b.currency,
               d.departs_at,
               b.refund_policy_id, b.refund_policy_version,
               p.name AS policy_name, p.tiers, p.destination,
               p.processing_hours, p.refund_service_fee,
               p.non_refundable_fares
          FROM bookings b
          JOIN departures d ON d.id = b.departure_id
          -- The version stamped on the booking, never the operator's current
          -- default. ADR-0015 rule 1 is this join.
          LEFT JOIN refund_policies p
                 ON p.id = b.refund_policy_id
                AND p.version = b.refund_policy_version
         WHERE upper(b.ref) = upper(@ref)
      '''),
      parameters: {'ref': TypedValue(Type.text, bookingRef.trim())},
    );
    return rows.isEmpty ? null : rows.first.toColumnMap();
  }

  RefundOffer _offer(Map<String, Object?> row, DateTime now) {
    final currency = Currency.byCode((row['currency'] as String).trim())!;
    final fare = Money(row['fare_minor'] as int, currency);
    final serviceFee = Money(row['service_fee_minor'] as int, currency);
    final departsAt = row['departs_at'] as DateTime;
    final state = row['state'] as String;
    final ref = row['ref'] as String;

    // Sold before the operator wrote any terms. "No policy" is the honest
    // answer; today's policy applied backwards is the dishonest one.
    if (row['refund_policy_id'] == null) {
      return RefundOffer(
        bookingRef: ref,
        state: state,
        departsAt: departsAt,
        fare: fare,
        serviceFee: serviceFee,
        policy: null,
        policyName: null,
        failureCode: ErrorCode.refundNoPolicy,
      );
    }

    final policy = _policyFrom({
      ...row,
      'id': row['refund_policy_id'],
      'version': row['refund_policy_version'],
      'name': row['policy_name'],
    }).policy;

    // Only a confirmed booking has money to give back. A reservation nobody
    // paid for is cancelled, not refunded, and saying so here keeps the
    // counter from offering zero francs with a straight face.
    if (state != 'confirmed') {
      return RefundOffer(
        bookingRef: ref,
        state: state,
        departsAt: departsAt,
        fare: fare,
        serviceFee: serviceFee,
        policy: policy,
        policyName: row['policy_name'] as String?,
        failureCode: ErrorCode.refundNotConfirmed,
      );
    }

    final quoted = domain.quoteRefund(
      faceValue: fare,
      serviceFee: serviceFee,
      departsAt: departsAt,
      now: now,
      policy: policy,
    );

    return RefundOffer(
      bookingRef: ref,
      state: state,
      departsAt: departsAt,
      fare: fare,
      serviceFee: serviceFee,
      policy: policy,
      policyName: row['policy_name'] as String?,
      quote: quoted.valueOrNull,
      failureCode: quoted.failureOrNull?.code,
    );
  }

  Future<void> _postRefundLedger(
    TxSession tx,
    LedgerTransaction posting, {
    required String operatorId,
    required String bookingId,
    required String refundId,
  }) async {
    // ONE txn_id for the whole movement. A uuid per row would give every
    // entry its own transaction, each of them unbalanced, and the deferred
    // constraint trigger would refuse the lot at COMMIT — which is the good
    // outcome, and still an outage rather than a refund.
    final generated = await tx.execute('SELECT gen_random_uuid() AS id');
    final txn = generated.first.toColumnMap()['id'].toString();

    for (final entry in posting.entries) {
      await tx.execute(
        Sql.named('''
          INSERT INTO ledger_entries
            (txn_id, account, direction, amount_minor, currency,
             operator_id, booking_id, refund_id, memo)
          VALUES (@txn, @account, @direction::ledger_direction,
                  @amount, @currency, @operator, @booking, @refund, @memo)
        '''),
        parameters: {
          'txn': TypedValue(Type.uuid, txn),
          'account': TypedValue(Type.text, entry.account),
          'direction': TypedValue(Type.text, entry.direction.name),
          'amount': TypedValue(Type.bigInteger, entry.amount.minor),
          'currency': TypedValue(Type.text, entry.amount.currency.code),
          'operator': TypedValue(Type.uuid, entry.operatorId ?? operatorId),
          'booking': TypedValue(Type.uuid, bookingId),
          'refund': TypedValue(Type.uuid, refundId),
          'memo': TypedValue(Type.text, entry.memo),
        },
        ignoreRows: true,
      );
    }
  }

  /// Six characters from the booking-reference alphabet, which already
  /// excludes the pairs a human confuses reading one out across a counter.
  static String _claimCode() {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final random = Random.secure();
    return List.generate(
      6,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  // ── Terms ─────────────────────────────────────────────────────────────────

  @override
  Future<List<RefundPolicySummary>> refundPolicies(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        // The booking count is what makes "can I just change this?" answerable
        // honestly: every row it counts is somebody entitled to these terms
        // and not to the ones the operator is about to write.
        final rows = await tx.execute(
          Sql.named('''
            SELECT p.id, p.version, p.name, p.tiers, p.destination,
                   p.processing_hours, p.refund_service_fee,
                   p.non_refundable_fares,
                   p.change_free_hours, p.change_fee_bps,
                   p.change_cutoff_hours,
                   p.missed_window_hours, p.missed_fee_bps, p.effective_from,
                   (o.default_refund_policy_id = p.id
                     AND o.default_refund_policy_version = p.version)
                     AS is_default,
                   (SELECT count(*) FROM bookings b
                     WHERE b.refund_policy_id = p.id
                       AND b.refund_policy_version = p.version)::int
                     AS booking_count
              FROM refund_policies p
              JOIN operators o ON o.id = p.operator_id
             WHERE p.operator_id = @operator
             ORDER BY p.name, p.version DESC
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return [for (final row in rows) _policyFrom(row.toColumnMap())];
      });

  @override
  Future<RefundPolicySummary> saveRefundPolicy({
    required String operatorId,
    required String name,
    required RefundPolicy policy,
    required String actorUserId,
    // Stored on the same row and stamped onto a booking by the same
    // `(id, version)` pair, so "the terms it was sold under" covers changes
    // as well as refunds without a second versioning scheme to keep honest.
    ChangePolicy change = ChangePolicy.standard,
    // And the same for the passenger who was late — one save, one version,
    // one commercial decision.
    MissedPolicy missed = MissedPolicy.notOffered,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // A new version, never an edit — and here the database agrees: 0014
    // revoked UPDATE on this table, so an adapter that tried to edit would
    // raise rather than quietly rewrite what somebody already paid for.
    final existing = await tx.execute(
      Sql.named('''
        SELECT id, COALESCE(MAX(version), 0) + 1 AS v
          FROM refund_policies
         WHERE operator_id = @operator AND name = @name
         GROUP BY id
         ORDER BY v DESC
         LIMIT 1
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'name': TypedValue(Type.text, name),
      },
    );

    final previous = existing.isEmpty ? null : existing.first.toColumnMap();
    final version = previous == null ? 1 : previous['v'] as int;

    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO refund_policies
          (id, version, operator_id, name, tiers, destination,
           processing_hours, refund_service_fee, non_refundable_fares,
           change_free_hours, change_fee_bps, change_cutoff_hours,
           missed_window_hours, missed_fee_bps,
           created_by)
        VALUES (COALESCE(@id, gen_random_uuid()), @version, @operator, @name,
                @tiers::jsonb, @destination, @hours, @refundFee, @fares,
                @changeFree, @changeFee, @changeCutoff,
                @missedWindow, @missedFee, @actor)
        RETURNING id, version, name, tiers, destination, processing_hours,
                  refund_service_fee, non_refundable_fares,
                  change_free_hours, change_fee_bps, change_cutoff_hours,
                  missed_window_hours, missed_fee_bps,
                  effective_from, FALSE AS is_default, 0 AS booking_count
      '''),
      parameters: {
        'id': TypedValue(Type.uuid, previous?['id']?.toString()),
        'version': TypedValue(Type.integer, version),
        'operator': TypedValue(Type.uuid, operatorId),
        'name': TypedValue(Type.text, name),
        'tiers': TypedValue(Type.text, jsonEncode(_tiers(policy))),
        'destination': TypedValue(Type.text, policy.destination.name),
        'hours': TypedValue(Type.integer, policy.processingWindow.inHours),
        'refundFee': TypedValue(Type.boolean, policy.refundServiceFee),
        'fares': TypedValue(
          Type.textArray,
          policy.nonRefundableFareCodes.toList()..sort(),
        ),
        'changeFree': TypedValue(Type.integer, change.freeBefore.inHours),
        'changeFee': TypedValue(Type.integer, change.feeBps),
        'changeCutoff': TypedValue(Type.integer, change.cutoff.inHours),
        'missedWindow': TypedValue(Type.integer, missed.window.inHours),
        'missedFee': TypedValue(Type.integer, missed.feeBps),
        'actor': TypedValue(Type.uuid, actorUserId),
      },
    );

    return _policyFrom(rows.first.toColumnMap());
  });

  @override
  Future<RefundPolicySummary?> setDefaultRefundPolicy({
    required String operatorId,
    required String? policyId,
    required int? version,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Both or neither, checked here as well as by the constraint, so a
    // half-formed request is a 400 rather than a 500 out of the database.
    if ((policyId == null) != (version == null)) return null;

    final updated = await tx.execute(
      Sql.named('''
        UPDATE operators
           SET default_refund_policy_id = @policy,
               default_refund_policy_version = @version
         WHERE id = @operator
           AND (@policy::uuid IS NULL OR EXISTS (
                 SELECT 1 FROM refund_policies p
                  WHERE p.id = @policy AND p.version = @version
                    AND p.operator_id = @operator))
        RETURNING default_refund_policy_id
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'policy': TypedValue(Type.uuid, policyId),
        'version': TypedValue(Type.integer, version),
      },
    );

    // No row means the policy named is not this operator's — which is a
    // refusal, not an error: RLS already made it invisible, and answering
    // "not found" is how a tenant learns nothing about another tenant's ids.
    if (updated.isEmpty) return null;
    if (policyId == null) return null;

    final rows = await tx.execute(
      Sql.named('''
        SELECT id, version, name, tiers, destination, processing_hours,
               refund_service_fee, non_refundable_fares, effective_from,
               TRUE AS is_default,
               (SELECT count(*) FROM bookings b
                 WHERE b.refund_policy_id = refund_policies.id
                   AND b.refund_policy_version = refund_policies.version)::int
                 AS booking_count
          FROM refund_policies
         WHERE id = @policy AND version = @version
      '''),
      parameters: {
        'policy': TypedValue(Type.uuid, policyId),
        'version': TypedValue(Type.integer, version),
      },
    );

    return rows.isEmpty ? null : _policyFrom(rows.first.toColumnMap());
  });

  static List<Map<String, Object?>> _tiers(RefundPolicy policy) => [
    for (final tier in policy.tiers)
      {
        'minLeadTimeMinutes': tier.minLeadTime.inMinutes,
        'rateBps': tier.rateBps,
        if (tier.flatFeeMinor > 0) 'flatFeeMinor': tier.flatFeeMinor,
      },
  ];

  static RefundPolicySummary _policyFrom(Map<String, Object?> row) {
    final raw = row['tiers'];
    final tiers = (raw is String ? jsonDecode(raw) : raw) as List<Object?>;

    return RefundPolicySummary(
      id: row['id'].toString(),
      version: row['version'] as int,
      name: row['name'] as String,
      isDefault: row['is_default'] as bool? ?? false,
      effectiveFrom:
          row['effective_from'] as DateTime? ?? DateTime.now().toUtc(),
      bookingCount: row['booking_count'] as int? ?? 0,
      // Defaulted column by column rather than as a whole: a row written
      // before 0025 has NULLs here, and D-08's numbers are what it has in
      // fact been behaving as all along.
      change: ChangePolicy(
        freeBefore: Duration(hours: row['change_free_hours'] as int? ?? 24),
        feeBps: row['change_fee_bps'] as int? ?? 1000,
        cutoff: Duration(hours: row['change_cutoff_hours'] as int? ?? 2),
      ),
      // Zero and zero for a row written before 0029, which is "not offered" —
      // and is exactly what such a policy has been doing all along.
      missed: MissedPolicy(
        window: Duration(hours: row['missed_window_hours'] as int? ?? 0),
        feeBps: row['missed_fee_bps'] as int? ?? 0,
      ),
      policy: RefundPolicy(
        id: row['id'].toString(),
        version: row['version'] as int,
        destination: RefundDestination.values.firstWhere(
          (d) => d.name == row['destination'],
          orElse: () => RefundDestination.source,
        ),
        processingWindow: Duration(
          hours: row['processing_hours'] as int? ?? 72,
        ),
        refundServiceFee: row['refund_service_fee'] as bool? ?? false,
        nonRefundableFareCodes: {
          ...?(row['non_refundable_fares'] as List?)?.map((f) => '$f'),
        },
        tiers: [
          for (final entry in tiers.cast<Map<String, Object?>>())
            RefundTier(
              minLeadTime: Duration(
                minutes: entry['minLeadTimeMinutes'] as int? ?? 0,
              ),
              rateBps: entry['rateBps'] as int? ?? 0,
              flatFeeMinor: entry['flatFeeMinor'] as int? ?? 0,
            ),
        ],
      ),
    );
  }

  @override
  Future<List<PaymentAccountSummary>> paymentAccounts(String operatorId) =>
      _db.transaction(DbScope.tenant(operatorId), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT id, rail_id, msisdn, display_name, verified_at, active
              FROM operator_payment_accounts
             WHERE operator_id = @operator AND active
             ORDER BY rail_id
          '''),
          parameters: {'operator': TypedValue(Type.uuid, operatorId)},
        );

        return [
          for (final row in rows)
            PaymentAccountSummary(
              id: row.toColumnMap()['id'].toString(),
              railId: row.toColumnMap()['rail_id'] as String,
              msisdn: row.toColumnMap()['msisdn'] as String,
              displayName: row.toColumnMap()['display_name'] as String,
              verified: row.toColumnMap()['verified_at'] != null,
              active: row.toColumnMap()['active'] as bool,
            ),
        ];
      });

  @override
  Future<PaymentAccountSummary?> savePaymentAccount({
    required String operatorId,
    required String railId,
    required String msisdn,
    required String displayName,
  }) => _db.transaction(DbScope.tenant(operatorId), (tx) async {
    // Deactivate rather than replace. An intent that already pushed money at
    // the old number has to keep resolving to it when somebody disputes the
    // payment six weeks from now — and the partial unique index covers only
    // active rows, which is what makes keeping the history possible.
    await tx.execute(
      Sql.named('''
        UPDATE operator_payment_accounts
           SET active = FALSE, updated_at = now()
         WHERE operator_id = @operator AND rail_id = @rail AND active
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'rail': TypedValue(Type.text, railId),
      },
      ignoreRows: true,
    );

    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO operator_payment_accounts
          (operator_id, rail_id, msisdn, display_name)
        VALUES (@operator, @rail, @msisdn, @name)
        RETURNING id, rail_id, msisdn, display_name, verified_at, active
      '''),
      parameters: {
        'operator': TypedValue(Type.uuid, operatorId),
        'rail': TypedValue(Type.text, railId),
        'msisdn': TypedValue(Type.text, msisdn),
        'name': TypedValue(Type.text, displayName),
      },
    );

    final row = rows.first.toColumnMap();
    return PaymentAccountSummary(
      id: row['id'].toString(),
      railId: row['rail_id'] as String,
      msisdn: row['msisdn'] as String,
      displayName: row['display_name'] as String,
      // Never on creation. A typo here sends every franc to a stranger,
      // permanently, because mobile money has no chargeback.
      verified: false,
      active: true,
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

  /// Row → layout. Public because the disruption desk decodes the same JSON
  /// when it puts one coach's passengers into another, and two decoders of
  /// one column is two ways to read a blocked seat.
  static SeatLayout decodeLayout(Map<String, dynamic> p) {
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
      // Read back as well as written. A decoder that quietly returns a coach
      // with no doors is a coach whose doors reappear only where somebody
      // wrote a second decoder — which is the thing this method exists to
      // prevent.
      features: decodeFeatures(p['features']),
      blocked: {for (final b in (p['blocked'] as List?) ?? const []) '$b'},
    );
  }

  /// The fittings column → the domain's list. Unknown types are dropped
  /// rather than thrown on: a layout drawn by a newer console must still be
  /// sellable by an older server, and a glyph nobody can draw is not a reason
  /// to refuse a departure.
  static List<LayoutFeature> decodeFeatures(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    final out = <LayoutFeature>[];
    for (final entry in (decoded as List? ?? const [])) {
      final f = (entry as Map).cast<String, Object?>();
      final type = LayoutFeatureType.values
          .where((t) => t.name == f['type'])
          .firstOrNull;
      if (type == null) continue;
      out.add(
        LayoutFeature(
          type,
          row: f['row'] as int? ?? 0,
          col: f['col'] as int? ?? 0,
        ),
      );
    }
    return out;
  }
}

/// One stop plus the name of the yard it named, straight off the join.
final class _Stop {
  const _Stop({required this.stop, this.stationName});
  final RouteStop stop;
  final String? stationName;
}
