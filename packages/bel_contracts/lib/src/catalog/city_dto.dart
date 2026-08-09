import '../json/json_codec.dart';

/// A city a traveller can search from or to.
///
/// The **name is already resolved** to the reader's language by the server,
/// rather than being sent as `nameFr` and `nameEn` for the client to choose
/// between. Two reasons: a third language later is a server change and not an
/// app release, and a client that picks a field is a client that will one day
/// pick the wrong one for a language it does not know it has.
final class CityDto {
  const CityDto({
    required this.code,
    required this.name,
    this.lat,
    this.lng,
  });

  /// The IATA-ish three-letter code — `BZV`, `PNR`. Stable, and what every
  /// other table references.
  final String code;

  final String name;

  /// Present so a later map view does not need a second endpoint. Null for a
  /// city whose coordinates nobody has entered yet, which is a normal state
  /// rather than an error.
  final double? lat;
  final double? lng;

  Map<String, Object?> toJson() => Wire.compact({
    'code': code,
    'name': name,
    'lat': lat,
    'lng': lng,
  });

  factory CityDto.fromJson(Map<String, Object?> json) => CityDto(
    code: Wire.requireString(json['code'], 'code'),
    name: Wire.requireString(json['name'], 'name'),
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
  );

  @override
  bool operator ==(Object other) => other is CityDto && other.code == code;
  @override
  int get hashCode => code.hashCode;
}
