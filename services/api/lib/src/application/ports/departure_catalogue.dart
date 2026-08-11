import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// What a traveller is looking for.
final class DepartureQuery {
  const DepartureQuery({
    required this.originCity,
    required this.destinationCity,
    required this.localDate,
    this.passengers = 1,
    this.operatorId,
    this.mode,
  });

  final String originCity;
  final String destinationCity;

  /// A **local calendar date**, not an instant.
  ///
  /// "Departures on the 15th" is a local-day question. Sending a UTC timestamp
  /// puts the 06:00 coach on the wrong day for anyone west of Greenwich, which
  /// includes every traveller we have.
  final DateTime localDate;

  final int passengers;
  final String? operatorId;
  final String? mode;
}

/// One sellable departure, straight off the read model.
///
/// Carries a fare and no service fee. The fee is a *market* fact, not a row in
/// anybody's database — the adapter would have to be told about Congo to know
/// it, and then adding a second country would mean editing SQL.
final class DepartureRow {
  const DepartureRow({
    required this.id,
    required this.operatorId,
    required this.operatorName,
    required this.mode,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.fare,
    required this.seatsAvailable,
    required this.capacity,
    required this.seatSelectionEnabled,
    this.operatorAccentHue,
    this.operatorLogoAsset,
    this.onTimeRate,
    this.amenities = const [],
    this.trackingTier,
    this.originStation,
    this.destinationStation,
  });

  final String id;
  final String operatorId;
  final String operatorName;
  final String mode;
  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final Money fare;

  /// A hint for rendering, and nothing more. Availability is re-validated
  /// inside the hold transaction, and the app says so in small print rather
  /// than pretending this number is authoritative (ADR-0012).
  final int seatsAvailable;

  final int capacity;
  final bool seatSelectionEnabled;
  final String? operatorAccentHue;
  final String? operatorLogoAsset;
  final int? onTimeRate;

  /// Which yard, when the operator has said. Null is common and honest — most
  /// companies run one terminal per city, and a name invented for the row
  /// would be a name nobody at the gate recognises.
  final StationRef? originStation;
  final StationRef? destinationStation;
  final List<String> amenities;
  final String? trackingTier;
}

/// Read-only catalogue: what is on sale, and which seats are free.
///
/// Search returns [DepartureRow] and the seat map returns a DTO directly, and
/// the asymmetry is deliberate rather than an oversight. Search needs a
/// service fee the database has no business knowing; a seat map needs nothing
/// the rows do not already hold, so mapping it through a second identical
/// type would be ceremony with no payoff.
abstract interface class DepartureCatalogue {
  Future<List<DepartureRow>> search(DepartureQuery query);

  /// Null when the departure does not exist. A cancelled one still resolves —
  /// somebody holding a ticket for it needs to see what happened to their
  /// coach.
  Future<SeatMapDto?> seatMap(String departureId);
}

/// A terminal, as much of it as a results row and a ticket need.
///
/// Deliberately not the console's `StationSummary`: a traveller has no use
/// for whether a yard is still open — they are only ever shown open ones —
/// and every field here is printed.
final class StationRef {
  const StationRef({
    required this.id,
    required this.name,
    this.lat,
    this.lng,
    this.boardingNotes,
  });

  final String id;
  final String name;
  final double? lat;
  final double? lng;
  final String? boardingNotes;
}
