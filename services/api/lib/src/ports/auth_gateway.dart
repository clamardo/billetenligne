/// Who the caller is, once their token has been verified.
///
/// Firebase answers *who you are* (ADR-0018). It does not decide *what you may
/// do* — capabilities are checked server-side against Postgres, because a
/// stale claim must never be able to authorise a refund.
final class Principal {
  const Principal({
    required this.userId,
    required this.authUid,
    this.tenantId,
    this.roles = const [],
    this.stationIds = const [],
    this.isPlatform = false,
    this.platformRole,
    this.language = 'fr',
  });

  final String userId;
  final String authUid;

  /// The operator this caller acts for. Null for a traveller.
  final String? tenantId;

  final List<String> roles;
  final List<String> stationIds;

  /// True only for our own staff, and only on the admin surface.
  final bool isPlatform;
  final String? platformRole;

  final String language;

  bool get isAnonymous => userId.isEmpty;

  static const anonymous = Principal(userId: '', authUid: '');
}

/// Verifies a bearer token. Implemented against the Firebase Admin SDK in
/// production and against the emulator locally (ADR-0020) — the port keeps
/// both out of the handlers.
abstract interface class AuthGateway {
  Future<Principal?> verify(String bearerToken);

  /// A credential for a traveller who has just answered a correct one-time
  /// code, to be **exchanged** with Firebase for an ID token and a refresh
  /// token — never presented to us as a bearer.
  ///
  /// This is ADR-0018's documented fallback, and it is the shape of it: we own
  /// the challenge, so the code can travel over a channel we can measure and
  /// price (email first, SMS second — ADR-0019), and Firebase still owns the
  /// session, the refresh rotation and the revocation. Rolling our own session
  /// token here would quietly take all four of those on.
  Future<String> mintCustomToken({
    required String uid,
    Map<String, Object?> claims,
    Duration ttl,
  });

  /// Mints a short-lived credential for a conductor, scoped to their assigned
  /// departures and expiring at end of shift. No standing credential on a
  /// device that gets lost (ADR-0013).
  Future<String> mintConductorToken({
    required String staffUserId,
    required String operatorId,
    required List<String> departureIds,
    required Duration ttl,
  });
}
