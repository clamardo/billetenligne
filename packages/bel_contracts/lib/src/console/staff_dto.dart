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
    required this.userId,
    required this.roles,
    required this.stationIds,
    required this.invitedAt,
    this.phone,
    this.fullName,
    this.revokedAt,
    this.staffRef,
  });

  /// The membership row — what the console addresses to change roles.
  final String id;

  /// The account behind it, which is what a rota names: the same person is
  /// one account whether they are staff at one company or three.
  final String userId;

  /// The operator's own short number for this person. An identifier, never a
  /// credential (ADR-0024) — it is stuck to the dashboard of a coach.
  final String? staffRef;

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
    'userId': userId,
    'staffRef': staffRef,
    'phone': phone,
    'fullName': fullName,
    'roles': roles,
    'stationIds': stationIds,
    'invitedAt': Wire.instant(invitedAt),
    'revokedAt': revokedAt == null ? null : Wire.instant(revokedAt!),
  });

  factory StaffDto.fromJson(Map<String, Object?> json) => StaffDto(
    id: Wire.requireString(json['id'], 'id'),
    userId: Wire.requireString(json['userId'], 'userId'),
    staffRef: json['staffRef'] as String?,
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

/// One person's place on one departure, on the wire.
///
/// Separate from [StaffDto] because it answers a different question. That one
/// says what somebody is allowed to do; this one says which coach they are on
/// tomorrow. A dispatcher filling a rota and a station manager granting a role
/// are two screens, two capabilities and two mistakes.
///
/// [staffRef] is the operator's own short identifier — a driver number. It is
/// on the roster and on the manifest to be **read aloud**, and it is never a
/// credential: sign-in is an emailed code plus, for anybody who can move other
/// people's money, an authenticator (ADR-0024). A number written on the
/// dashboard of a coach is not a secret.
final class CrewMemberDto {
  const CrewMemberDto({
    required this.userId,
    required this.role,
    required this.assignedAt,
    this.fullName,
    this.staffRef,
    this.phone,
  });

  final String userId;

  /// `driver` or `conductor`. Two jobs, because on an intercity coach here
  /// they are usually two people and only one of them holds the handset.
  final String role;

  final DateTime assignedAt;
  final String? fullName;
  final String? staffRef;
  final String? phone;

  Map<String, Object?> toJson() => Wire.compact({
    'userId': userId,
    'role': role,
    'assignedAt': Wire.instant(assignedAt),
    'fullName': fullName,
    'staffRef': staffRef,
    'phone': phone,
  });

  factory CrewMemberDto.fromJson(Map<String, Object?> json) => CrewMemberDto(
    userId: Wire.requireString(json['userId'], 'userId'),
    role: Wire.requireString(json['role'], 'role'),
    assignedAt: Wire.readInstant(json['assignedAt'], field: 'assignedAt'),
    fullName: json['fullName'] as String?,
    staffRef: json['staffRef'] as String?,
    phone: json['phone'] as String?,
  );
}
