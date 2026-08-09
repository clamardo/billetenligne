import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';

import '../application/ports/identity_gateway.dart';

/// The real gateway: our API for the challenge, Firebase for the session.
///
/// Thin, like `ApiTravelGateway`. The refresh logic, the rotation and what to
/// do with a revoked token all live in `BelSession`, where the operator
/// console will get them too — reimplementing any of it here is how two
/// surfaces end up disagreeing about when a token is stale.
final class ApiIdentityGateway implements IdentityGateway {
  const ApiIdentityGateway({
    required BelApiClient client,
    required BelSession session,
  }) : _client = client,
       _session = session;

  final BelApiClient _client;
  final BelSession _session;

  @override
  AccountDto? get account => _session.account;

  @override
  bool get isSignedIn => _session.isSignedIn;

  @override
  Future<bool> restore() async {
    if (!await _session.restore()) return false;

    // The refresh worked, which proves Firebase still vouches for them. It
    // does not prove they are still our customer — a refresh token survives a
    // disabled account — so the profile is re-read before the app treats them
    // as signed in.
    try {
      await _client.me();
      return true;
    } on ServerRefused catch (e) {
      if (e.status == 401 || e.status == 403) {
        await _session.invalidate();
        return false;
      }
      return true;
    } on ApiFailure {
      // Offline at launch. The session is kept; the funnel will find out at
      // the moment it matters, which is the hold.
      return true;
    }
  }

  @override
  Future<SignInChallengeDto> requestCode(String email) =>
      _client.startSignIn(StartSignInRequest.email(email));

  @override
  Future<AccountDto> submitCode({
    required String challengeId,
    required String code,
  }) async {
    final session = await _client.verifySignIn(
      VerifySignInRequest(challengeId: challengeId, code: code),
    );
    // Exchanges the custom token for a Firebase session and stores the refresh
    // token. Until this returns the traveller is not signed in, which is why
    // the account comes back from here rather than from the response above.
    await _session.adopt(session);
    return session.account;
  }

  @override
  Future<void> signOut() => _session.signOut();
}
