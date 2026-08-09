import 'package:bel_contracts/bel_contracts.dart';

/// Everything becoming a customer needs from the outside world.
///
/// Separate from `TravelGateway` because it is a genuinely separate
/// conversation: search-seatmap-hold-release is one exchange with our API,
/// while signing in is two exchanges with our API *and* one with Firebase
/// (ADR-0024). Folding them together would put the token exchange behind a
/// port named after travel.
abstract interface class IdentityGateway {
  /// Who is signed in, or null. Read synchronously because the funnel checks
  /// it on the way into a hold, and a future there would mean a frame where
  /// the app does not know whether to show a sign-in screen.
  AccountDto? get account;

  bool get isSignedIn;

  /// Restores a session from secure storage at launch. False when there was
  /// none, or when it is no longer good.
  Future<bool> restore();

  /// "Send me a code."
  Future<SignInChallengeDto> requestCode(String email);

  /// Answers the code, exchanges the credential, and returns the traveller.
  Future<AccountDto> submitCode({
    required String challengeId,
    required String code,
  });

  Future<void> signOut();
}
