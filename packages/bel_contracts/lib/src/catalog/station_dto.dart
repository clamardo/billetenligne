import '../json/json_codec.dart';

/// A terminal, on the wire.
///
/// The traveller-facing half of this is two strings: what the yard is called
/// and how to find it. Both are printed on the ticket, which is the whole
/// reason the table stopped being decorative — "Brazzaville" is not an
/// instruction to somebody with a suitcase at half past five in the morning.
///
/// Coordinates travel as a pair or not at all. A latitude with no longitude
/// is a marker in the Gulf of Guinea, so the two are validated together at
/// the edge and carried together here.
final class StationDto {
  const StationDto({
    required this.id,
    required this.name,
    this.cityCode,
    this.active = true,
    this.lat,
    this.lng,
    this.boardingNotes,
  });

  final String id;
  final String name;

  /// Set when the console lists terminals, where the city is what groups
  /// them. Absent on a search row or a ticket: the journey already says which
  /// city, and repeating it under the yard's name is noise on a small screen.
  final String? cityCode;

  /// A closed terminal is still listed in the console — reopening one should
  /// not need a database — and is never offered to a traveller.
  final bool active;

  final double? lat;
  final double? lng;

  /// What a map cannot say: *entrée par la rue derrière la station Total,
  /// guichet 3*. Printed under the name rather than kept in an agency's head.
  final String? boardingNotes;

  bool get hasCoordinates => lat != null && lng != null;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'cityCode': cityCode,
    'name': name,
    'active': active,
    'lat': lat,
    'lng': lng,
    'boardingNotes': boardingNotes,
  });

  factory StationDto.fromJson(Map<String, Object?> json) => StationDto(
    id: Wire.requireString(json['id'], 'id'),
    name: Wire.requireString(json['name'], 'name'),
    cityCode: json['cityCode'] as String?,
    active: json['active'] as bool? ?? true,
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
    boardingNotes: json['boardingNotes'] as String?,
  );
}
