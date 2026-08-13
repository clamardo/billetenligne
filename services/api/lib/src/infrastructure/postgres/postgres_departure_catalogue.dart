import 'dart:convert';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/city_catalogue.dart';
import '../../application/ports/departure_catalogue.dart';
import '../db/database.dart';

/// The read side of the catalogue.
///
/// Runs under [DbScope.anonymous], because browsing needs no account and
/// forcing sign-up before a traveller sees a price is the biggest avoidable
/// drop-off in this funnel (ADR-0013). The public policies in migration 0005
/// are what make an unauthenticated connection able to see anything at all.
final class PostgresDepartureCatalogue implements DepartureCatalogue {
  const PostgresDepartureCatalogue(
    this._db, {
    this.timeZone = 'Africa/Brazzaville',
  });

  final Database _db;

  /// The market's timezone, passed to Postgres rather than hardcoded in SQL.
  ///
  /// "Departures on the 15th" is a local-day question, and a second country
  /// will have a different answer to it. This is the one line that has to
  /// change; nothing else in the query does.
  final String timeZone;

  @override
  Future<List<DepartureRow>> search(DepartureQuery query) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        // The availability count is computed in the same statement rather than
        // in a second round trip: a search on 2G that needs two requests is a
        // screen that visibly stalls, and the count is a rendering hint anyway
        // — the hold transaction is what actually decides.
        final rows = await tx.execute(
          Sql.named('''
            -- Every place a coach can be got on or off, numbered the way the
            -- departure's own `road_span` numbers them: the origin is 0, each
            -- `route_stops.sequence` follows, and the destination is last
            -- (ADR-0025). The endpoints are not rows in `route_stops` and
            -- have to be added here, which is also where their asymmetry
            -- gets stated — nobody alights where the coach starts, and
            -- nobody boards where it finishes.
            WITH road AS (
              SELECT r.id AS route_id, 0 AS position, r.origin_city AS city,
                     0 AS offset_minutes, TRUE AS boards, FALSE AS alights
                FROM routes r
               UNION ALL
              SELECT rs.route_id, rs.sequence, rs.city_code, rs.offset_minutes,
                     rs.allows_boarding, rs.allows_alighting
                FROM route_stops rs
               UNION ALL
              SELECT r.id,
                     1 + (SELECT count(*)::int FROM route_stops x
                           WHERE x.route_id = r.id),
                     r.destination_city, r.duration_minutes, FALSE, TRUE
                FROM routes r
            )
            SELECT d.id,
                   d.operator_id,
                   COALESCE(o.trading_name, o.legal_name) AS operator_name,
                   o.accent_hue,
                   o.logo_asset,
                   -- A column, not a computation. The figure moves once a
                   -- night; a join over ninety days of departures on every
                   -- search is how a results screen gets slow (0027).
                   o.on_time_rate,
                   -- The pair the traveller actually asked for. On a whole
                   -- road these are the route's own ends; on a leg they are
                   -- the towns the operator priced, and the row that comes
                   -- back is an ordinary departure between them.
                   COALESCE(leg.from_city, r.origin_city)    AS origin_city,
                   COALESCE(leg.to_city, r.destination_city) AS destination_city,
                   -- Two joins to the same table, which is the honest shape:
                   -- a departure leaves one yard and arrives at another, and
                   -- in a two-terminal city they are the fact that decides
                   -- where somebody stands at half past five.
                   os.id AS origin_station_id, os.name AS origin_station_name,
                   os.lat AS origin_lat, os.lng AS origin_lng,
                   os.boarding_notes AS origin_notes,
                   ds.id AS destination_station_id,
                   ds.name AS destination_station_name,
                   d.departs_at + make_interval(
                     mins => COALESCE(leg.from_offset, 0)) AS departs_at,
                   CASE WHEN leg.to_offset IS NULL THEN d.arrives_at
                        ELSE d.departs_at
                             + make_interval(mins => leg.to_offset) END
                     AS arrives_at,
                   -- The operator's price for that piece of road, never a
                   -- fraction of the through fare we invented (ADR-0025).
                   COALESCE(leg.fare_minor, d.fare_minor) AS fare_minor,
                   COALESCE(leg.currency, d.currency)     AS currency,
                   d.capacity,
                   d.seat_selection_enabled,
                   d.mode,
                   d.amenities,
                   -- Where the coach stops on the way. A correlated
                   -- subquery on `d.route_id` rather than a join, because a
                   -- join to a one-to-many multiplies the seat count this
                   -- statement is also computing — and `route_id` is
                   -- functionally dependent on the grouped primary key,
                   -- which `r.id` is not.
                   -- Bounded by the leg, so a Dolisie–Pointe-Noire row does
                   -- not advertise a town the passenger will never see.
                   (SELECT array_agg(rs.city_code ORDER BY rs.sequence)
                      FROM route_stops rs
                     WHERE rs.route_id = d.route_id
                       AND rs.sequence > COALESCE(leg.from_position,
                                                  lower(d.road_span))
                       AND rs.sequence < COALESCE(leg.to_position,
                                                  upper(d.road_span))) AS via,
                   -- Asked of occupancy rather than of `seats.state`, because
                   -- on a leg the state is the wrong question: a seat sold
                   -- Brazzaville→Dolisie reads `partial` and is exactly what
                   -- somebody boarding at Dolisie should be offered. A hold
                   -- that has lapsed occupies nothing, here as everywhere.
                   COUNT(s.seat_label) FILTER (
                     WHERE s.state <> 'blocked'
                       AND NOT EXISTS (
                         SELECT 1 FROM seat_occupancy oc
                          WHERE oc.departure_id = d.id
                            AND oc.seat_label = s.seat_label
                            AND (oc.held_until IS NULL
                                 OR oc.held_until > now())
                            AND oc.span && int4range(
                                  COALESCE(leg.from_position,
                                           lower(d.road_span)),
                                  COALESCE(leg.to_position,
                                           upper(d.road_span))))
                   )::int             AS seats_available
              FROM departures d
              JOIN routes    r ON r.id = d.route_id
              JOIN operators o ON o.id = d.operator_id
              -- Deliberately no join to `vehicles`. The traveller needs the
              -- mode and the amenities, both captured onto the departure by
              -- migration 0006; the rest of that table is the operator's
              -- business, and the public role has no grant on it at all.
              LEFT JOIN stations os ON os.id = d.origin_station_id
              LEFT JOIN stations ds ON ds.id = d.destination_station_id
              LEFT JOIN seats s ON s.departure_id = d.id
              -- The piece of this road that answers the question, when the
              -- road's own ends do not. `LEFT JOIN LATERAL` and not a
              -- subquery in the SELECT list, because six columns come out of
              -- it and every one of them has to agree about which leg.
              LEFT JOIN LATERAL (
                SELECT sf.from_position, sf.to_position,
                       sf.fare_minor, sf.currency,
                       fs.city AS from_city, ts.city AS to_city,
                       fs.offset_minutes AS from_offset,
                       ts.offset_minutes AS to_offset
                  FROM segment_fares sf
                  JOIN road fs ON fs.route_id = sf.route_id
                              AND fs.position = sf.from_position
                  JOIN road ts ON ts.route_id = sf.route_id
                              AND ts.position = sf.to_position
                 WHERE sf.route_id = d.route_id
                   AND sf.active
                   AND fs.city = @from AND ts.city = @to
                   -- A set-down-only stop can end a leg and cannot start
                   -- one. The detail every naive model gets wrong.
                   AND fs.boards AND ts.alights
                 -- A road that visits a town twice has two answers; the
                 -- earlier boarding is the one a traveller meant.
                 ORDER BY sf.from_position
                 LIMIT 1
              ) leg ON TRUE
             WHERE ((r.origin_city = @from AND r.destination_city = @to)
                    OR leg.from_position IS NOT NULL)
               AND ((d.departs_at + make_interval(
                       mins => COALESCE(leg.from_offset, 0)))
                     AT TIME ZONE @tz)::date = @date::date
               AND d.status <> 'cancelled'
               -- A coach that has left is not a search result. The traveller
               -- searching at 06:05 for the 06:00 needs the 09:00, not a row
               -- they cannot buy — and on a leg it is the *boarding* time
               -- that decides, because the coach left Brazzaville hours
               -- before it reaches the town they are standing in.
               AND d.departs_at + make_interval(
                     mins => COALESCE(leg.from_offset, 0)) > now()
               AND (d.sales_close_at IS NULL OR d.sales_close_at > now())
               -- An operator whose insurance lapsed disappears from search
               -- rather than selling a seat and refusing it at checkout
               -- (03-operator-lifecycle.md §3.3, §4). Their coaches still
               -- run and their tickets are still valid — only the sale is
               -- gone.
               AND o.sales_blocked_at IS NULL
               AND (@operator::uuid IS NULL OR d.operator_id = @operator::uuid)
               AND (@mode::text IS NULL OR d.mode = @mode::text)
               -- Everything strictly after the last row of the previous
               -- page. A row comparison rather than two ORs, so the index on
               -- `(departs_at, id)` is usable and the tie between two
               -- companies running the same 06:00 is broken the same way the
               -- ORDER BY breaks it.
               AND (@afterAt::timestamptz IS NULL
                    OR (d.departs_at + make_interval(
                          mins => COALESCE(leg.from_offset, 0)), d.id)
                       > (@afterAt::timestamptz, @afterId::uuid))
             GROUP BY d.id, o.trading_name, o.legal_name, o.accent_hue,
                      o.logo_asset, o.on_time_rate, r.origin_city,
                      r.destination_city, r.duration_minutes, os.id, ds.id,
                      leg.from_position, leg.to_position, leg.fare_minor,
                      leg.currency, leg.from_city, leg.to_city,
                      leg.from_offset, leg.to_offset
             -- The id is part of the order, not decoration: without it two
             -- coaches leaving at the same minute have no defined order, and
             -- a keyset cursor over an undefined order skips rows.
             ORDER BY d.departs_at + make_interval(
                        mins => COALESCE(leg.from_offset, 0)), d.id
             LIMIT @limit
          '''),
          parameters: {
            'from': TypedValue(Type.text, query.originCity),
            'to': TypedValue(Type.text, query.destinationCity),
            'tz': TypedValue(Type.text, timeZone),
            'date': TypedValue(Type.text, _isoDate(query.localDate)),
            'operator': TypedValue(Type.uuid, query.operatorId),
            'mode': TypedValue(Type.text, query.mode),
            'afterAt': TypedValue(Type.timestampTz, query.after?.departsAt),
            'afterId': TypedValue(Type.uuid, query.after?.id),
            'limit': TypedValue(Type.integer, query.limit),
          },
        );

        return [for (final row in rows) _toRow(row.toColumnMap())];
      });

  DepartureRow _toRow(Map<String, dynamic> r) {
    final currency =
        Currency.byCode((r['currency'] as String).trim()) ?? Currency.xaf;

    return DepartureRow(
      id: r['id'] as String,
      operatorId: r['operator_id'] as String,
      operatorName: r['operator_name'] as String,
      mode: (r['mode'] as String?) ?? 'bus',
      originCity: r['origin_city'] as String,
      destinationCity: r['destination_city'] as String,
      departsAt: (r['departs_at'] as DateTime).toUtc(),
      arrivesAt: (r['arrives_at'] as DateTime).toUtc(),
      fare: Money(r['fare_minor'] as int, currency),
      seatsAvailable: (r['seats_available'] as int?) ?? 0,
      capacity: r['capacity'] as int,
      seatSelectionEnabled: (r['seat_selection_enabled'] as bool?) ?? true,
      operatorAccentHue: r['accent_hue'] as String?,
      operatorLogoAsset: r['logo_asset'] as String?,
      amenities: (r['amenities'] as List?)?.cast<String>() ?? const [],
      // Empty for most roads in this market, which is why it is a list and
      // not a nullable one: "no stops" and "we do not know the stops" are
      // the same thing here, and a road is described or it is not.
      via: (r['via'] as List?)?.cast<String>() ?? const [],
      // Null below the sample floor, and null is drawn as nothing rather than
      // as a zero: an operator nobody has data about must not read as the
      // worst one on the screen.
      onTimeRate: r['on_time_rate'] as int?,
      originStation: _station(
        r['origin_station_id'],
        r['origin_station_name'],
        lat: r['origin_lat'] as double?,
        lng: r['origin_lng'] as double?,
        notes: r['origin_notes'] as String?,
      ),
      destinationStation: _station(
        r['destination_station_id'],
        r['destination_station_name'],
      ),
    );
  }

  /// Null rather than a placeholder when the operator has not said. A row
  /// that invented "Gare routière" would send somebody to a gate nobody at
  /// that company has heard of.
  static StationRef? _station(
    Object? id,
    Object? name, {
    double? lat,
    double? lng,
    String? notes,
  }) => id == null || name == null
      ? null
      : StationRef(
          id: id.toString(),
          name: name as String,
          lat: lat,
          lng: lng,
          boardingNotes: notes,
        );

  @override
  Future<SeatMapDto?> seatMap(String departureId) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        final header = await tx.execute(
          Sql.named('''
            SELECT l.version, l.mode, l.sections, l.features
              FROM departures d
              JOIN seat_layouts l ON l.id = d.seat_layout_id
             WHERE d.id = @id
          '''),
          parameters: {'id': TypedValue(Type.uuid, departureId)},
        );
        if (header.isEmpty) return null;

        final h = header.first.toColumnMap();

        final seats = await tx.execute(
          Sql.named('''
            SELECT seat_label,
                   section_code,
                   fare_minor,
                   currency,
                   -- A hold that has lapsed reads as available. The sweeper is
                   -- a tidy-up, never the thing that decides — otherwise a
                   -- stalled worker shows a coach as full when it is empty.
                   CASE WHEN state = 'held' AND held_until <= now()
                        THEN 'available' ELSE state::text END AS state
              FROM seats
             WHERE departure_id = @id
             ORDER BY seat_label
          '''),
          parameters: {'id': TypedValue(Type.uuid, departureId)},
        );

        return SeatMapDto(
          departureId: departureId,
          mode: (h['mode'] as String?) ?? 'bus',
          layoutVersion: (h['version'] as int?) ?? 1,
          sections: _sections(h['sections']),
          features: _features(h['features']),
          seats: [for (final row in seats) _toSeat(row.toColumnMap())],
        );
      });

  SeatDto _toSeat(Map<String, dynamic> r) {
    final currency =
        Currency.byCode((r['currency'] as String).trim()) ?? Currency.xaf;
    return SeatDto(
      label: r['seat_label'] as String,
      sectionCode: r['section_code'] as String,
      // Available is named rather than defaulted to, and the default is the
      // unsellable answer. `partial` — a seat sold for part of the road
      // (ADR-0025) — arrives here as `held`, which is what a client that has
      // never heard of segments needs to be told, and any state a later
      // migration adds gets the same treatment. A seat map that fails open
      // sells a seat somebody is already sitting in.
      status: switch (r['state'] as String) {
        'available' => SeatStatusDto.available,
        'sold' => SeatStatusDto.sold,
        'blocked' => SeatStatusDto.blocked,
        _ => SeatStatusDto.held,
      },
      // Per seat, so a VIP row never surprises anyone at checkout.
      fare: Money(r['fare_minor'] as int, currency),
    );
  }

  /// The stored JSON shape lives here, in infrastructure, and nowhere else.
  /// The domain's [CabinSection] has no `fromJson` on purpose — it would drag
  /// a storage format into a package that is supposed to be pure.
  static List<CabinSectionDto> _sections(Object? raw) {
    final list = _asList(raw);
    return [
      for (final entry in list)
        if (entry is Map)
          CabinSectionDto(
            code: entry['code'] as String? ?? 'STD',
            labelKey: entry['labelKey'] as String? ?? 'seat.class.standard',
            rows: (entry['rows'] as num?)?.toInt() ?? 0,
            abreast: entry['abreast'] as String? ?? '2+2',
            pitchCm: (entry['pitchCm'] as num?)?.toInt(),
          ),
    ];
  }

  static List<LayoutFeatureDto> _features(Object? raw) {
    final list = _asList(raw);
    return [
      for (final entry in list)
        if (entry is Map)
          LayoutFeatureDto(
            type: entry['type'] as String? ?? 'unknown',
            row: (entry['row'] as num?)?.toInt() ?? 0,
            col: (entry['col'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  /// JSONB arrives already decoded from the driver, but a text column or an
  /// older row may still be a string. Both are accepted rather than one
  /// crashing a seat map at boarding time.
  static List<Object?> _asList(Object? raw) => switch (raw) {
    final List l => l,
    final String s => jsonDecode(s) is List ? jsonDecode(s) as List : const [],
    _ => const [],
  };

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Cities, on the public surface.
///
/// Lives beside the departure catalogue because it reads the same two tables,
/// and stays a separate class because it answers a question with a completely
/// different lifetime — see `CityCatalogue` for why that matters.
final class PostgresCityCatalogue implements CityCatalogue {
  const PostgresCityCatalogue(this._db);

  final Database _db;

  @override
  Future<List<CityDto>> servedCities({required String language}) =>
      _db.transaction(const DbScope.anonymous(), (tx) async {
        // The join is what makes this "cities you can reach" rather than
        // "rows in the cities table". An operator that has not opened a route
        // to Ouesso yet means Ouesso is not offered, and a traveller never
        // searches a pair that can only answer nothing.
        //
        // `active` on the route, not on the departure: a route with no coach
        // scheduled this week is still a route, and hiding it would make the
        // picker flicker as timetables are edited.
        final rows = await tx.execute(
          Sql.named('''
            SELECT c.code,
                   CASE WHEN @language = 'en' THEN c.name_en ELSE c.name_fr END
                     AS name,
                   c.lat, c.lng
              FROM cities c
             WHERE EXISTS (
                     SELECT 1 FROM routes r
                      WHERE r.active
                        AND (r.origin_city = c.code OR r.destination_city = c.code)
                   )
             ORDER BY name
          '''),
          parameters: {'language': TypedValue(Type.text, language)},
        );

        return [
          for (final row in rows)
            CityDto(
              code: row.toColumnMap()['code'] as String,
              name: row.toColumnMap()['name'] as String,
              lat: row.toColumnMap()['lat'] as double?,
              lng: row.toColumnMap()['lng'] as double?,
            ),
        ];
      });
}
