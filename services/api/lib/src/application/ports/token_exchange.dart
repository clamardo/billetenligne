/// Trading a custom token for a session, server-side (J11).
///
/// The handset does this itself: it is a native app, its storage is the
/// Keychain and the Android Keystore, and a refresh token there is as safe as
/// anything on the device. A browser has no such place, so for the web
/// surfaces the exchange happens here and the refresh token never leaves the
/// server.
///
/// A port because it is the one part of this that reaches Google, and because
/// the fakes composition has to be able to sign somebody in with nothing
/// installed.
library;

/// What Firebase answers with, in the two shapes it answers in.
final class ExchangedSession {
  const ExchangedSession({
    required this.idToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String idToken;

  /// Rotated by Firebase on every refresh. The new one must be stored, or the
  /// session ends at the next refresh.
  final String refreshToken;

  final Duration expiresIn;
}

/// Thrown when Firebase refuses. Distinct from a network failure on purpose:
/// a refused refresh token is a session that is over — the account was
/// disabled, the token was revoked — and retrying it forever is how a signed
/// out person keeps being asked to wait.
final class TokenExchangeRefused implements Exception {
  const TokenExchangeRefused(this.reason);
  final String reason;
  @override
  String toString() => 'token exchange refused: $reason';
}

abstract interface class TokenExchange {
  /// `accounts:signInWithCustomToken` — the exchange the app would otherwise
  /// do for itself.
  Future<ExchangedSession> exchangeCustomToken(String customToken);

  /// `securetoken.googleapis.com/v1/token` with `grant_type=refresh_token`.
  Future<ExchangedSession> refresh(String refreshToken);
}
