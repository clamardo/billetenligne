import 'dart:convert';

import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';
import 'station_dto.dart';

/// One sellable departure, as a search result row.
///
/// Shaped for what `KTripCard` actually renders, so the client never has to
/// join three responses to draw one row on a 2G connection.
final class DepartureSummaryDto {
  const DepartureSummaryDto({
    required this.id,
    required this.operatorId,
    required this.operatorName,
    required this.mode,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.fare,
    required this.serviceFee,
    required this.seatsAvailable,
    required this.capacity,
    required this.seatSelectionEnabled,
    this.operatorAccentHue,
    this.operatorLogoUrl,
    this.onTimeRate,
    this.amenities = const [],
    this.via = const [],
    this.trackingTier,
    this.originStation,
    this.destinationStation,
  });

  final String id;
  final String operatorId;
  final String operatorName;

  /// `bus` or `air` (ADR-0017). The client picks a silhouette from this; it
  /// changes nothing else in the funnel.
  final String mode;

  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final Money fare;
  final Money serviceFee;

  /// A hint for rendering only. Availability is re-validated server-side at
  /// hold time, inside a transaction, and the UI says so in small print rather
  /// than pretending the cache is authoritative (ADR-0012).
  final int seatsAvailable;

  final int capacity;

  /// False for operators selling unnumbered inventory — the funnel is
  /// identical, the client just shows a quantity stepper.
  final bool seatSelectionEnabled;

  final String? operatorAccentHue;

  /// Where the operator's mark can be fetched, already resolved.
  ///
  /// A URL and not the storage key: *where a file lives* is a fact about the
  /// deployment — the account, the container, whatever CDN sits in front of
  /// them — and a client that built this URL itself would be a client that
  /// breaks on a storage migration. Null when the company never uploaded one,
  /// and also when this deployment has no storage configured, which is why
  /// the monogram fallback is keyed off the URL rather than off a key.
  final String? operatorLogoUrl;

  /// 0–100. Surfaced honestly, so reliability becomes a competitive
  /// advantage rather than a hidden cost.
  final int? onTimeRate;

  final List<String> amenities;

  /// The towns this coach passes through, in order, as city codes.
  ///
  /// Codes rather than names, because the client already holds the city
  /// catalogue for its own search form and a server that sent names would be
  /// sending prose (ADR-0008) — and the wrong prose, in whichever language
  /// the row was written in.
  ///
  /// **Passing through is not the same as stopping to sell**: these are the
  /// towns on the road, and buying a seat between two of them is not built.
  final List<String> via;

  /// `gps`, `checkpoint` or `schedule` (ADR-0014). Absent means no tracking.
  final String? trackingTier;

  /// Which yard, when the operator has named one. Null is common and honest:
  /// most companies run a single terminal per city, and inventing "Gare
  /// routière" for the row would send somebody to a gate nobody at that
  /// company has heard of.
  final StationDto? originStation;
  final StationDto? destinationStation;

  Duration get duration => arrivesAt.difference(departsAt);
  Money get total => fare + serviceFee;
  bool get isSoldOut => seatsAvailable <= 0;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'operatorId': operatorId,
    'operatorName': operatorName,
    'mode': mode,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'departsAt': Wire.instant(departsAt),
    'arrivesAt': Wire.instant(arrivesAt),
    'fare': Wire.money(fare),
    'serviceFee': Wire.money(serviceFee),
    'seatsAvailable': seatsAvailable,
    'capacity': capacity,
    'seatSelectionEnabled': seatSelectionEnabled,
    'operatorAccentHue': operatorAccentHue,
    'operatorLogoUrl': operatorLogoUrl,
    'onTimeRate': onTimeRate,
    'amenities': amenities.isEmpty ? null : amenities,
    'via': via.isEmpty ? null : via,
    'trackingTier': trackingTier,
    'originStation': originStation?.toJson(),
    'destinationStation': destinationStation?.toJson(),
  });

  factory DepartureSummaryDto.fromJson(Map<String, Object?> json) =>
      DepartureSummaryDto(
        id: Wire.requireString(json['id'], 'id'),
        operatorId: Wire.requireString(json['operatorId'], 'operatorId'),
        operatorName: Wire.requireString(json['operatorName'], 'operatorName'),
        mode: Wire.requireString(json['mode'], 'mode'),
        originCity: Wire.requireString(json['originCity'], 'originCity'),
        destinationCity: Wire.requireString(
          json['destinationCity'],
          'destinationCity',
        ),
        departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
        arrivesAt: Wire.readInstant(json['arrivesAt'], field: 'arrivesAt'),
        fare: Wire.readMoney(json['fare'], field: 'fare'),
        serviceFee: Wire.readMoney(json['serviceFee'], field: 'serviceFee'),
        seatsAvailable: Wire.requireInt(
          json['seatsAvailable'],
          'seatsAvailable',
        ),
        capacity: Wire.requireInt(json['capacity'], 'capacity'),
        seatSelectionEnabled: json['seatSelectionEnabled'] as bool? ?? true,
        operatorAccentHue: json['operatorAccentHue'] as String?,
        operatorLogoUrl: json['operatorLogoUrl'] as String?,
        onTimeRate: json['onTimeRate'] as int?,
        amenities: (json['amenities'] as List?)?.cast<String>() ?? const [],
        via: (json['via'] as List?)?.cast<String>() ?? const [],
        trackingTier: json['trackingTier'] as String?,
        originStation: _station(json['originStation']),
        destinationStation: _station(json['destinationStation']),
      );

  static StationDto? _station(Object? raw) =>
      raw is Map ? StationDto.fromJson(raw.cast<String, Object?>()) : null;
}

/// Search request. Sent as query parameters; this type keeps the names in one
/// place so client and server cannot drift.
final class SearchDeparturesQuery {
  const SearchDeparturesQuery({
    required this.originCity,
    required this.destinationCity,
    required this.date,
    this.passengers = 1,
    this.operatorId,
    this.mode,
    this.cursor,
    this.limit,
    this.sort = TripSort.earliest,
    this.departFromHour,
    this.departToHour,
    this.maxFareMinor,
  });

  final String originCity;
  final String destinationCity;

  /// Local calendar date in the market's timezone, `YYYY-MM-DD`. Not an
  /// instant: "departures on the 15th" is a local-day question, and sending
  /// a UTC timestamp makes the 06:00 coach fall on the wrong day.
  final DateTime date;

  final int passengers;
  final String? operatorId;
  final String? mode;

  /// Where the previous page stopped, opaque to the client.
  ///
  /// Absent means the first page. It is deliberately not a page *number*:
  /// departures are created and cancelled while somebody is scrolling, and an
  /// offset silently skips or repeats a coach every time the list underneath
  /// it moves. See [SearchCursor].
  final String? cursor;

  /// How many rows to answer with. Null takes the server's own default, and
  /// the server clamps it — a page size is a query parameter, and "give me
  /// ten thousand" is a slow query anybody can ask for by typing.
  final int? limit;

  /// Earliest, cheapest or fastest (§6.1). Part of the cursor as well as of
  /// the request — see [SearchCursor.sort].
  final TripSort sort;

  /// A departure window, as **local hours of the searched day**, `0`–`24`.
  ///
  /// Hours rather than instants because that is the question somebody is
  /// actually asking: *something in the morning*. An instant pair would make
  /// the client compute the market's offset, which is the one calculation
  /// this codebase keeps refusing to do outside Postgres.
  final int? departFromHour;
  final int? departToHour;

  /// A price ceiling, in minor units of the market's currency. The **fare**,
  /// not the total: it is what the rows show and what an operator sets, and a
  /// ceiling that silently included our service fee would filter out a coach
  /// priced exactly at the figure the traveller typed.
  final int? maxFareMinor;

  Map<String, String> toQuery() => {
    'from': originCity,
    'to': destinationCity,
    'date': _isoDate(date),
    'passengers': '$passengers',
    if (operatorId != null) 'operator': operatorId!,
    if (mode != null) 'mode': mode!,
    if (cursor != null) 'cursor': cursor!,
    if (limit != null) 'limit': '$limit',
    // Omitted at the default, so the commonest search is the shortest URL and
    // the CDN sees one cache key for it rather than two.
    if (sort != TripSort.earliest) 'sort': sort.name,
    if (departFromHour != null) 'fromHour': '$departFromHour',
    if (departToHour != null) 'toHour': '$departToHour',
    if (maxFareMinor != null) 'maxFare': '$maxFareMinor',
  };

  factory SearchDeparturesQuery.fromQuery(Map<String, String> q) =>
      SearchDeparturesQuery(
        originCity:
            q['from'] ?? (throw const WireFormatException('from', 'required')),
        destinationCity:
            q['to'] ?? (throw const WireFormatException('to', 'required')),
        date: DateTime.parse(
          q['date'] ?? (throw const WireFormatException('date', 'required')),
        ),
        passengers: int.tryParse(q['passengers'] ?? '1') ?? 1,
        operatorId: q['operator'],
        mode: q['mode'],
        cursor: q['cursor'],
        limit: q['limit'] == null ? null : int.tryParse(q['limit']!),
        // An unknown sort is a refusal rather than a silent `earliest`: a
        // client asking for one we removed should find out.
        sort:
            q['sort'] == null
                ? TripSort.earliest
                : TripSort.byName(q['sort']) ??
                      (throw const WireFormatException('sort', 'unknown')),
        departFromHour: _hour(q['fromHour'], 'fromHour'),
        departToHour: _hour(q['toHour'], 'toHour'),
        maxFareMinor: q['maxFare'] == null
            ? null
            : int.tryParse(q['maxFare']!) ??
                  (throw const WireFormatException('maxFare', 'malformed')),
      );

  /// A local hour of the day, or a refusal. Bounded here rather than in SQL
  /// so `fromHour=99` is a 400 with the field named, not an empty list a
  /// traveller reads as "no coaches".
  static int? _hour(String? raw, String field) {
    if (raw == null) return null;
    final value = int.tryParse(raw);
    if (value == null || value < 0 || value > 24) {
      throw WireFormatException(field, 'out of range');
    }
    return value;
  }

  /// The same search, from where this page stopped.
  SearchDeparturesQuery nextPage(String cursor) => SearchDeparturesQuery(
    originCity: originCity,
    destinationCity: destinationCity,
    date: date,
    passengers: passengers,
    operatorId: operatorId,
    mode: mode,
    cursor: cursor,
    limit: limit,
    sort: sort,
    departFromHour: departFromHour,
    departToHour: departToHour,
    maxFareMinor: maxFareMinor,
  );

  /// The same road and day, ordered or narrowed differently.
  ///
  /// **Drops the cursor, always.** Changing the sort or a filter is a new
  /// list, and carrying the old cursor into it is the exact mistake §6.2
  /// refuses — the server would answer with a refusal, and the screen would
  /// show it to somebody who only tapped "le moins cher".
  SearchDeparturesQuery refined({
    TripSort? sort,
    String? operatorId,
    int? departFromHour,
    int? departToHour,
    int? maxFareMinor,
    bool clearOperator = false,
    bool clearWindow = false,
    bool clearCeiling = false,
  }) => SearchDeparturesQuery(
    originCity: originCity,
    destinationCity: destinationCity,
    date: date,
    passengers: passengers,
    operatorId: clearOperator ? null : operatorId ?? this.operatorId,
    mode: mode,
    limit: limit,
    sort: sort ?? this.sort,
    departFromHour: clearWindow
        ? null
        : departFromHour ?? this.departFromHour,
    departToHour: clearWindow ? null : departToHour ?? this.departToHour,
    maxFareMinor: clearCeiling ? null : maxFareMinor ?? this.maxFareMinor,
  );

  /// Whether anything narrows this search beyond the road and the day. What
  /// the screen renders a "clear" affordance from.
  bool get isFiltered =>
      operatorId != null ||
      departFromHour != null ||
      departToHour != null ||
      maxFareMinor != null;

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Where a page of search results stopped.
///
/// **A keyset, not an offset.** Departures are created, cancelled and sold out
/// while somebody is scrolling a results list on a slow connection, and
/// `OFFSET 20` on a list that gained a row silently repeats a coach and loses
/// another. A cursor that names the last row — when it leaves, and which one
/// it was — cannot: the next page is everything strictly after that point,
/// whatever happened in between.
///
/// The pair is needed, not just the time: two companies scheduling the 06:00
/// on the same road is the ordinary case, not the exception, and a cursor
/// carrying only the instant would drop one of them.
///
/// **Opaque to the client.** It is encoded rather than sent as two fields so
/// that a client cannot construct one — the moment a handset builds its own
/// cursor, the ordering becomes a shared contract instead of a server
/// decision, and it can never be changed again.
final class SearchCursor {
  const SearchCursor({
    required this.departsAt,
    required this.id,
    this.sort = TripSort.earliest,
    this.value,
  });

  /// The instant the last row on the previous page leaves.
  final DateTime departsAt;

  /// That row's departure id, which breaks the tie.
  final String id;

  /// The order this cursor was minted under (§6.2).
  ///
  /// Carried because a keyset is defined *against* an order, so a cursor from
  /// an `earliest` page is meaningless on a `cheapest` one. The server
  /// compares it to the request and refuses a disagreement rather than
  /// re-sorting, because a silent re-sort produces duplicate and missing rows
  /// across a page boundary — the failure that reads as the inventory being
  /// wrong.
  final TripSort sort;

  /// The leading sort key of the last row, when the order has one: the fare
  /// in minor units under `cheapest`, the leg's length in seconds under
  /// `fastest`. Null under `earliest`, whose only keys are the two above.
  final int? value;

  /// Base64url, unpadded — it travels in a query string.
  String encode() => base64Url
      .encode(
        utf8.encode(
          '${sort.name}.${value ?? ''}.'
          '${departsAt.toUtc().microsecondsSinceEpoch}.$id',
        ),
      )
      .replaceAll('=', '');

  /// Throws [WireFormatException] on anything malformed.
  ///
  /// A refusal, rather than falling back to the first page: a client that
  /// silently gets page one back when it asked for page five scrolls forever
  /// and never notices.
  factory SearchCursor.decode(String raw) {
    try {
      final padded = raw.padRight((raw.length + 3) ~/ 4 * 4, '=');
      final text = utf8.decode(base64Url.decode(padded));
      // `sort.value.micros.id`, and the id is the only part that may itself
      // contain a dot, so the split is bounded from the left.
      final parts = text.split('.');

      // A two-part cursor is one this server minted before sorting existed,
      // and it means `earliest` — which is what that build could produce.
      // Three lines so a traveller mid-scroll across a deploy keeps their
      // place rather than being told their cursor is malformed.
      if (parts.length == 2) {
        return SearchCursor(
          departsAt: DateTime.fromMicrosecondsSinceEpoch(
            int.parse(parts[0]),
            isUtc: true,
          ),
          id: parts[1],
        );
      }

      if (parts.length < 4) {
        throw const WireFormatException('cursor', 'malformed');
      }
      final sort = TripSort.byName(parts[0]);
      if (sort == null) throw const WireFormatException('cursor', 'malformed');

      final id = parts.sublist(3).join('.');
      if (id.isEmpty) throw const WireFormatException('cursor', 'malformed');

      final value = parts[1].isEmpty ? null : int.parse(parts[1]);
      // An order with a second key needs it. Without it the keyset comparison
      // in SQL is NULL for every row, and the traveller reads an empty page
      // as "no coaches on this road" rather than as the malformed cursor it
      // is.
      if (sort.needsValue && value == null) {
        throw const WireFormatException('cursor', 'malformed');
      }

      return SearchCursor(
        sort: sort,
        value: value,
        departsAt: DateTime.fromMicrosecondsSinceEpoch(
          int.parse(parts[2]),
          isUtc: true,
        ),
        id: id,
      );
    } on WireFormatException {
      rethrow;
    } on Object {
      throw const WireFormatException('cursor', 'malformed');
    }
  }
}

/// One page of search results, on the wire.
///
/// The list was already wrapped in an object — a bare JSON array leaves
/// nowhere to put anything that is about the page rather than about a row —
/// and this is the type that had been implied by hand at both ends. Written
/// down once, so the server that builds it and the client that reads it
/// cannot disagree about a field name (ADR-0004).
final class TripPageDto {
  const TripPageDto({
    required this.items,
    this.nextCursor,
    this.query = const {},
  });

  final List<DepartureSummaryDto> items;

  /// Where the next page starts, or null when this is the last one.
  final String? nextCursor;

  /// The search this answers, echoed back.
  ///
  /// A client rendering a stale response can tell which day it is looking at
  /// — a real bug on a slow connection, where two searches are in flight and
  /// the second answers first.
  final Map<String, String> query;

  bool get hasMore => nextCursor != null;

  Map<String, Object?> toJson() => {
    'items': [for (final d in items) d.toJson()],
    if (nextCursor != null) 'nextCursor': nextCursor,
    'query': query,
  };

  factory TripPageDto.fromJson(Map<String, Object?> json) => TripPageDto(
    items: Wire.readList(
      json['items'],
      DepartureSummaryDto.fromJson,
      field: 'items',
    ),
    nextCursor: json['nextCursor'] as String?,
    query: {
      for (final e in (json['query'] as Map? ?? const {}).entries)
        '${e.key}': '${e.value}',
    },
  );
}
