import '../ports/auth_gateway.dart';

/// Deterministic auth for tests and the local emulator loop.
///
/// Tokens are `fake:<userId>`, resolved against a registry the test controls.
/// Production verifies a real Firebase JWT behind the same port (ADR-0018),
/// so nothing above this line knows the difference.
final class FakeAuthGateway implements AuthGateway {
  FakeAuthGateway([Map<String, Principal>? seed]) : _principals = {...?seed};

  final Map<String, Principal> _principals;

  void register(String token, Principal principal) =>
      _principals[token] = principal;

  @override
  Future<Principal?> verify(String bearerToken) async =>
      _principals[bearerToken];

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
