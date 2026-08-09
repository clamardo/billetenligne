import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

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
    this.operatorLogoAsset,
    this.onTimeRate,
    this.amenities = const [],
    this.trackingTier,
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
  final String? operatorLogoAsset;

  /// 0–100. Surfaced honestly, so reliability becomes a competitive
  /// advantage rather than a hidden cost.
  final int? onTimeRate;

  final List<String> amenities;

  /// `gps`, `checkpoint` or `schedule` (ADR-0014). Absent means no tracking.
  final String? trackingTier;

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
    'operatorLogoAsset': operatorLogoAsset,
    'onTimeRate': onTimeRate,
    'amenities': amenities.isEmpty ? null : amenities,
    'trackingTier': trackingTier,
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
        operatorLogoAsset: json['operatorLogoAsset'] as String?,
        onTimeRate: json['onTimeRate'] as int?,
        amenities: (json['amenities'] as List?)?.cast<String>() ?? const [],
        trackingTier: json['trackingTier'] as String?,
      );
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

  Map<String, String> toQuery() => {
    'from': originCity,
    'to': destinationCity,
    'date': _isoDate(date),
    'passengers': '$passengers',
    if (operatorId != null) 'operator': operatorId!,
    if (mode != null) 'mode': mode!,
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
      );

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
