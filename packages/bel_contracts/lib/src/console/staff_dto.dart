import '../json/json_codec.dart';

/// One member of an operator's staff, on the wire.
///
/// [phone] and [fullName] describe the person, not the membership — they are
/// read off `user_accounts` on the join this DTO is built from, and are null
/// only in the gap between an invite being written and the console's next
/// read, which does not happen in practice because both are one round trip.
///
/// A revoked member is still listed, never dropped: the console's staff list
/// is also the record of who has ever had a key to this till, and dropping a
/// row the moment it is revoked would make "who did we trust in March"
/// unanswerable without a database.
final class StaffDto {
  const StaffDto({
    required this.id,
    required this.roles,
    required this.stationIds,
    required this.invitedAt,
    this.phone,
    this.fullName,
    this.revokedAt,
  });

  final String id;
  final String? phone;
  final String? fullName;

  /// ADR-0011's role matrix. Additive — most people hold more than one.
  final List<String> roles;

  /// Empty means every station, which is only ever true of a whole-org role.
  final List<String> stationIds;

  final DateTime invitedAt;
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'phone': phone,
    'fullName': fullName,
    'roles': roles,
    'stationIds': stationIds,
    'invitedAt': Wire.instant(invitedAt),
    'revokedAt': revokedAt == null ? null : Wire.instant(revokedAt!),
  });

  factory StaffDto.fromJson(Map<String, Object?> json) => StaffDto(
    id: Wire.requireString(json['id'], 'id'),
    phone: json['phone'] as String?,
    fullName: json['fullName'] as String?,
    roles: [for (final r in (json['roles'] as List?) ?? const []) '$r'],
    stationIds: [
      for (final s in (json['stationIds'] as List?) ?? const []) '$s',
    ],
    invitedAt: Wire.readInstant(json['invitedAt'], field: 'invitedAt'),
    revokedAt: json['revokedAt'] == null
        ? null
        : Wire.readInstant(json['revokedAt'], field: 'revokedAt'),
  );
}
