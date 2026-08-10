import '../ports/auth_gateway.dart';

/// Deterministic auth for tests and the local emulator loop.
///
/// Tokens are `fake:<userId>`, resolved against a registry the test controls.
/// Production verifies a real Firebase JWT behind the same port (ADR-0018),
/// so nothing above this line knows the difference.
final class FakeAuthGateway implements AuthGateway {
  FakeAuthGateway([Map<String, Principal>? seed]) : _principals = {...?seed};

  final Map<String, Principal> _principals;

  /// One traveller, so a fresh clone can hold a seat without standing up
  /// Firebase first. Used only when no DATABASE_URL is set — the same
  /// condition under which the inventory is a fake — so this token cannot
  /// reach a real database even by accident.
  factory FakeAuthGateway.demo() => FakeAuthGateway({
    'fake:traveller': const Principal(
      userId: 'u-demo-traveller',
      authUid: 'demo',
      language: 'fr',
    ),
    // One operator owner, on the same tenant the memory adapters seed. It
    // exists so the console surface can be driven over a real socket without
    // Postgres: the routes that *refuse* a request — a malformed seat layout,
    // a capability somebody does not hold — decide before they ever reach a
    // repository, and that is the half worth proving on a URL.
    //
    // Anything that does reach a repository answers 503 in this composition,
    // which is itself the assertion that validation ran first.
    'fake:operator': const Principal(
      userId: 'u-demo-owner',
      authUid: 'demo-owner',
      tenantId: 'op-demo',
      roles: ['org_owner'],
      language: 'fr',
    ),
  });

  void register(String token, Principal principal) =>
      _principals[token] = principal;

  @override
  Future<Principal?> verify(String bearerToken) async =>
      _principals[bearerToken];

  /// Registers the minted token as a bearer, which the real gateway does not
  /// and cannot do — a Firebase custom token has to be exchanged first.
  ///
  /// That difference is deliberate and it is what lets `tool/smoke_api.sh`
  /// drive a whole sign-in against a fresh clone with no emulator running.
  /// The cost is that this adapter is a shortcut through a step production
  /// takes for real, so the *exchange* is proven by the Firebase emulator test
  /// instead of here.
  @override
  Future<String> mintCustomToken({
    required String uid,
    Map<String, Object?> claims = const {},
    Duration ttl = const Duration(hours: 1),
  }) async {
    final token = 'fake:$uid';
    _principals[token] = Principal(
      userId: uid,
      authUid: uid,
      tenantId: claims['tenantId'] as String?,
      roles: (claims['roles'] as List?)?.cast<String>() ?? const [],
      language: 'fr',
    );
    return token;
  }

  @override
  Future<String> mintConductorToken({
    required String staffUserId,
    required String operatorId,
    required List<String> departureIds,
    required Duration ttl,
  }) async {
    final token = 'fake:conductor:$staffUserId';
    _principals[token] = Principal(
      userId: staffUserId,
      authUid: staffUserId,
      tenantId: operatorId,
      roles: const ['conductor'],
    );
    return token;
  }
}
