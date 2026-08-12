import '../json/json_codec.dart';

/// A standing request to be told when a full coach has room again.
///
/// The DTO says nothing about position, place in line, or odds. There is no
/// queue behind it — the first person to pay gets the seat, and everybody
/// waiting is told at the same moment — so a field like `position` would be a
/// number the server could not honour.
final class SeatAlertDto {
  const SeatAlertDto({
    required this.id,
    required this.departureId,
    required this.seatsWanted,
    required this.createdAt,
    this.notifiedAt,
  });

  final String id;
  final String departureId;

  /// How many seats would make the trip worth taking. A family of four is not
  /// served by one seat coming free, and telling them it was would be a
  /// message that wastes a journey to a station.
  final int seatsWanted;

  final DateTime createdAt;

  /// When the message went out, if it has. A spent alert is still returned:
  /// "I was told, late" and "I was never told" are different complaints, and
  /// only a kept row can tell them apart.
  final DateTime? notifiedAt;

  bool get isWaiting => notifiedAt == null;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'departureId': departureId,
    'seatsWanted': seatsWanted,
    'createdAt': Wire.instant(createdAt),
    'notifiedAt': notifiedAt == null ? null : Wire.instant(notifiedAt!),
  });

  factory SeatAlertDto.fromJson(Map<String, Object?> json) => SeatAlertDto(
    id: Wire.requireString(json['id'], 'id'),
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    seatsWanted: Wire.requireInt(json['seatsWanted'], 'seatsWanted'),
    createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
    notifiedAt: Wire.readInstantOrNull(json['notifiedAt'], field: 'notifiedAt'),
  );
}

/// What the traveller asks for when they tap "tell me if a seat frees up".
///
/// One number, and it is deliberately the request rather than the response:
/// the server decides whether the coach is worth waiting for, and answers
/// with the row it actually stored.
final class WatchSeatsRequest {
  const WatchSeatsRequest({required this.seatsWanted});

  final int seatsWanted;

  Map<String, Object?> toJson() => {'seatsWanted': seatsWanted};

  factory WatchSeatsRequest.fromJson(Map<String, Object?> json) =>
      WatchSeatsRequest(
        seatsWanted: Wire.requireInt(json['seatsWanted'], 'seatsWanted'),
      );
}
