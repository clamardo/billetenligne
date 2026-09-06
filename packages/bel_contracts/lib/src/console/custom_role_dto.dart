import '../json/json_codec.dart';

/// One of an operator's own roles — cloned from a default role
/// (`Capability.operatorRoles`) or built from scratch, renamed and with its
/// own capability set, and grantable to staff exactly like `org_owner` or
/// `vendor` once it exists.
final class CustomRoleDto {
  const CustomRoleDto({
    required this.id,
    required this.name,
    required this.capabilities,
    required this.createdAt,
    this.clonedFromRole,
  });

  final String id;
  final String name;

  /// ADR-0011's capability strings. Free-form, not one of the fixed sets in
  /// `Capability.operatorRoles` — this is the whole point of a custom role.
  final List<String> capabilities;

  /// The default role this one started as a copy of, if any. Kept only as a
  /// hint for the console's own UI (so a later edit can still say "based on
  /// station manager") — nothing server-side reads it back.
  final String? clonedFromRole;

  final DateTime createdAt;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'name': name,
    'capabilities': capabilities,
    'clonedFromRole': clonedFromRole,
    'createdAt': Wire.instant(createdAt),
  });

  factory CustomRoleDto.fromJson(Map<String, Object?> json) => CustomRoleDto(
    id: Wire.requireString(json['id'], 'id'),
    name: Wire.requireString(json['name'], 'name'),
    capabilities: [
      for (final c in (json['capabilities'] as List?) ?? const []) '$c',
    ],
    clonedFromRole: json['clonedFromRole'] as String?,
    createdAt: Wire.readInstant(json['createdAt'], field: 'createdAt'),
  );
}

/// The default roles a custom role may be cloned from, and what each one
/// carries today — so the console never has to hardcode its own copy of
/// `Capability.operatorRoles` to offer "start from station_manager" as a
/// choice.
final class DefaultRoleDto {
  const DefaultRoleDto({required this.name, required this.capabilities});

  final String name;
  final List<String> capabilities;

  Map<String, Object?> toJson() =>
      Wire.compact({'name': name, 'capabilities': capabilities});

  factory DefaultRoleDto.fromJson(Map<String, Object?> json) => DefaultRoleDto(
    name: Wire.requireString(json['name'], 'name'),
    capabilities: [
      for (final c in (json['capabilities'] as List?) ?? const []) '$c',
    ],
  );
}
