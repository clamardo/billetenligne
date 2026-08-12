import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/departure_catalogue.dart';

sealed class SearchFailure extends DomainFailure {
  const SearchFailure();
}

final class SameOriginAndDestination extends SearchFailure {
  const SameOriginAndDestination(this.city);
  final String city;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'city': city};
}

final class UnreasonablePassengerCount extends SearchFailure {
  const UnreasonablePassengerCount(this.requested, this.max);
  final int requested;
  final int max;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'requested': requested, 'max': max};
}

/// A cursor a client could not have got from us.
///
/// Refused rather than treated as "start again", because a client that asks
/// for page five and silently receives page one scrolls forever and nobody
/// finds out.
final class UnreadableCursor extends SearchFailure {
  const UnreadableCursor();
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => const {'field': 'cursor'};
}

/// Searching more than a year out is a typo, not a plan. Refused with a code
/// rather than an empty list, because "no results" and "you typed 2027 by
/// accident" should not look identical to a traveller.
final class DateOutOfRange extends SearchFailure {
  const DateOutOfRange(this.date);
  final DateTime date;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'date': date.toIso8601String()};
}

/// Find sellable departures for a day.
///
/// The first screen a traveller sees with anything on it, and the one that
/// decides whether they finish the funnel. Two decisions live here:
///
///   * **The service fee is added here, once**, not by the adapter and not by
///     the client. The database has no business knowing what Congo charges,
///     and a client that computes the total is a client that can disagree with
///     the receipt.
///   * **Sold-out departures are returned, not filtered.** Seeing "complet" on
///     the 06:00 is how a traveller learns to book earlier next time. Hiding
///     it just makes the service look empty.
/// One page of results, and where the next one starts.
///
/// A class rather than a bare list because "there is more" is a fact the
/// screen needs and cannot derive: a full page is not evidence of another one,
/// and a client that guessed would show a spinner at the bottom of every
/// complete list.
final class SearchPage {
  const SearchPage({required this.departures, this.nextCursor});

  final List<DepartureSummaryDto> departures;

  /// Null when this is the last page. Opaque; it goes back out as `cursor`.
  final String? nextCursor;
}

final class SearchDepartures {
  const SearchDepartures({
    required DepartureCatalogue catalogue,
    this.market = Market.current,
    this.maxPassengers = 6,
    this.horizon = const Duration(days: 365),
    this.pageSize = 20,
    this.maxPageSize = 100,
  }) : _catalogue = catalogue;

  final DepartureCatalogue _catalogue;
  final Market market;
  final int maxPassengers;
  final Duration horizon;

  /// How many rows a page holds when the client does not say.
  ///
  /// Twenty rather than a hundred: a results list on 2G is paid for by the
  /// byte, and the traveller who wants the 06:00 has already found it by row
  /// three. The rest arrives when they scroll.
  final int pageSize;

  /// The most anybody may ask for. Clamped rather than trusted — the page
  /// size is a query parameter, and a thousand rows is a slow query somebody
  /// can ask for by typing.
  final int maxPageSize;

  Future<Result<SearchPage, SearchFailure>> call(
    SearchDeparturesQuery query, {
    required DateTime now,
  }) async {
    final from = query.originCity.trim().toUpperCase();
    final to = query.destinationCity.trim().toUpperCase();

    if (from == to) return Err(SameOriginAndDestination(from));
    if (query.passengers < 1 || query.passengers > maxPassengers) {
      return Err(UnreasonablePassengerCount(query.passengers, maxPassengers));
    }
    if (query.date.isAfter(now.add(horizon))) {
      return Err(DateOutOfRange(query.date));
    }

    final SearchCursor? after;
    try {
      after = query.cursor == null ? null : SearchCursor.decode(query.cursor!);
    } on WireFormatException {
      return const Err(UnreadableCursor());
    }

    final size = (query.limit ?? pageSize).clamp(1, maxPageSize);

    final rows = await _catalogue.search(
      DepartureQuery(
        originCity: from,
        destinationCity: to,
        localDate: query.date,
        passengers: query.passengers,
        operatorId: query.operatorId,
        mode: query.mode,
        after: after,
        // One more than a page. The extra row is never returned — it is the
        // whole answer to "is there another page?", and it costs one row
        // rather than a second query over the same joins.
        limit: size + 1,
      ),
    );

    final hasMore = rows.length > size;
    final page = hasMore ? rows.take(size).toList() : rows;

    return Ok(
      SearchPage(
        departures: [for (final row in page) _toDto(row)],
        // Named from the last row actually returned, so the next page begins
        // exactly where this one stopped whatever happens in between.
        nextCursor: hasMore && page.isNotEmpty
            ? SearchCursor(
                departsAt: page.last.departsAt,
                id: page.last.id,
              ).encode()
            : null,
      ),
    );
  }

  DepartureSummaryDto _toDto(DepartureRow row) => DepartureSummaryDto(
    id: row.id,
    operatorId: row.operatorId,
    operatorName: row.operatorName,
    mode: row.mode,
    originCity: row.originCity,
    destinationCity: row.destinationCity,
    departsAt: row.departsAt,
    arrivesAt: row.arrivesAt,
    fare: row.fare,
    serviceFee: market.serviceFee,
    seatsAvailable: row.seatsAvailable,
    capacity: row.capacity,
    seatSelectionEnabled: row.seatSelectionEnabled,
    operatorAccentHue: row.operatorAccentHue,
    operatorLogoAsset: row.operatorLogoAsset,
    onTimeRate: row.onTimeRate,
    amenities: row.amenities,
    via: row.via,
    trackingTier: row.trackingTier,
    originStation: _station(row.originStation),
    destinationStation: _station(row.destinationStation),
  );

  /// The catalogue's own `StationRef`, on the wire. Two types rather than one
  /// shared across the boundary, because the console's station carries an
  /// `active` flag that means nothing to a traveller — they are only ever
  /// shown open ones.
  static StationDto? _station(StationRef? s) => s == null
      ? null
      : StationDto(
          id: s.id,
          name: s.name,
          lat: s.lat,
          lng: s.lng,
          boardingNotes: s.boardingNotes,
        );
}
