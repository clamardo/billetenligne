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
final class SearchDepartures {
  const SearchDepartures({
    required DepartureCatalogue catalogue,
    this.market = Market.current,
    this.maxPassengers = 6,
    this.horizon = const Duration(days: 365),
  }) : _catalogue = catalogue;

  final DepartureCatalogue _catalogue;
  final Market market;
  final int maxPassengers;
  final Duration horizon;

  Future<Result<List<DepartureSummaryDto>, SearchFailure>> call(
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

    final rows = await _catalogue.search(
      DepartureQuery(
        originCity: from,
        destinationCity: to,
        localDate: query.date,
        passengers: query.passengers,
        operatorId: query.operatorId,
        mode: query.mode,
      ),
    );

    return Ok([for (final row in rows) _toDto(row)]);
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
    trackingTier: row.trackingTier,
  );
}
