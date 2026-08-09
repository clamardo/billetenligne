import '../ports/auth_gateway.dart';
import '../ports/capability.dart';

/// Proof that a request has been scoped to exactly one operator.
///
/// A repository method physically cannot be called without one of these
/// (ADR-0011 defence #3). That turns "remember to filter by tenant" from
/// discipline into something the compiler asks about.
final class TenantScope {
  const TenantScope._(this.operatorId, this._capabilities, this.stationIds);

  final String operatorId;
  final Set<String> _capabilities;

  /// A vendor is scoped to their station(s): the Pointe-Noire agent must not
  /// be able to open the Brazzaville till.
  final List<String> stationIds;

  bool can(String capability) => _capabilities.contains(capability);

  bool coversStation(String stationId) =>
      stationIds.isEmpty || stationIds.contains(stationId);

  static TenantScope? forPrincipal(Principal p) {
    final tenant = p.tenantId;
    if (tenant == null || tenant.isEmpty) return null;
    return TenantScope._(tenant, Capability.forRoles(p.roles), p.stationIds);
  }

  @override
  String toString() => 'TenantScope($operatorId, ${_capabilities.length} caps)';
}

/// Cross-tenant authority, for the admin surface only.
///
/// Deliberately a *different type* from [TenantScope], so a repository that
/// takes a tenant scope can never accidentally be handed platform authority.
/// Every read made under one of these is written to the audit log with an
/// actor and a reason.
final class PlatformScope {
  const PlatformScope._(this.actorUserId, this._capabilities, this.reason);

  final String actorUserId;
  final Set<String> _capabilities;

  /// Mandatory on every cross-tenant action. "Why" is the question an audit
  /// answers, and it cannot be reconstructed afterwards.
  final String reason;

  bool can(String capability) => _capabilities.contains(capability);

  static PlatformScope? forPrincipal(Principal p, {required String reason}) {
    if (!p.isPlatform || p.platformRole == null) return null;
    if (reason.trim().isEmpty) return null;
    return PlatformScope._(
      p.userId,
      Capability.forRoles([p.platformRole!], platform: true),
      reason,
    );
  }
}

/// The session variables the database reads to enforce RLS.
///
/// Set on the connection before anything else runs. `app.tenant_id` empty
/// means the connection sees no tenant-scoped rows at all — a code path that
/// forgets to scope fails closed, never open.
final class SessionVariables {
  const SessionVariables({this.tenantId, this.isPlatform = false});

  final String? tenantId;
  final bool isPlatform;

  factory SessionVariables.forTenant(TenantScope scope) =>
      SessionVariables(tenantId: scope.operatorId);

  factory SessionVariables.forPlatform(PlatformScope _) =>
      const SessionVariables(isPlatform: true);

  /// Nothing scoped is visible. The correct default.
  static const none = SessionVariables();

  Map<String, String> toSettings() => {
    'app.tenant_id': tenantId ?? '',
    'app.platform': isPlatform ? 'on' : 'off',
  };
}
