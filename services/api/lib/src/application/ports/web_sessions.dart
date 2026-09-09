/// A browser session the browser holds no credential for (J11).
///
/// **What the browser gets is a selector**: an opaque random value in an
/// `HttpOnly` cookie, which script running in the page cannot read. Everything
/// that is actually a credential — the Firebase refresh token, the ID token
/// currently in hand — stays here.
///
/// That division is the whole slice. A refresh token in `localStorage` turns
/// one XSS into a ninety-day account takeover; the same XSS against a cookie
/// the page cannot read costs the attacker whatever they can do from inside
/// that page while it is open, and ends when the session is revoked.
///
/// Every method runs on the identity surface (`DbScope.identity`): resolving a
/// session happens before a request has a tenant or a surface, exactly as
/// signing in does.
library;

/// What a resolved session hands back: a bearer the middleware can verify,
/// exactly as if the caller had sent one.
final class WebSessionToken {
  const WebSessionToken({required this.idToken, required this.userId});

  final String idToken;

  /// Our own account id, from the row rather than from the token. Used only
  /// for the access log and for revoking a person's other sessions — the
  /// principal still comes from verifying [idToken], because a session row is
  /// not evidence that an account is still a customer.
  final String userId;
}

abstract interface class WebSessions {
  /// Opens a session for somebody who has just proven who they are.
  ///
  /// Returns the **selector** — the value that goes into the cookie and is
  /// never stored. What is stored is its hash.
  Future<String> open({
    required String userId,
    required String refreshToken,
    required String idToken,
    required DateTime idTokenExpiresAt,
    required Duration ttl,
    String? userAgent,
    String? ip,
  });

  /// The bearer for a selector, refreshing it if it has expired.
  ///
  /// Null for a selector that is unknown, revoked, or past its own expiry —
  /// one answer for all three, because distinguishing them tells somebody
  /// holding a guessed cookie which guess was closer.
  ///
  /// **Rotation is serialised on the row.** Firebase rotates the refresh
  /// token on use, so two tabs waking together must not both spend it: the
  /// second would invalidate the first and sign somebody out for having
  /// opened a second tab.
  Future<WebSessionToken?> resolve(String selector);

  /// Ends a session server-side. Returns false when there was nothing live to
  /// end, which is not an error — signing out twice is signing out.
  Future<bool> revoke(String selector);

  /// Ends every live session for one account. What a stolen laptop needs.
  Future<int> revokeAllFor(String userId);
}

/// The null implementation, for a deployment with no database behind it.
///
/// Refuses rather than pretends: a build with no store cannot keep a session,
/// and answering "signed in" from memory would be a sign-in that survives
/// exactly one process restart and nobody could explain.
final class NoWebSessions implements WebSessions {
  const NoWebSessions();

  @override
  Future<String> open({
    required String userId,
    required String refreshToken,
    required String idToken,
    required DateTime idTokenExpiresAt,
    required Duration ttl,
    String? userAgent,
    String? ip,
  }) async => throw UnsupportedError('no session store on this deployment');

  @override
  Future<WebSessionToken?> resolve(String selector) async => null;

  @override
  Future<bool> revoke(String selector) async => false;

  @override
  Future<int> revokeAllFor(String userId) async => 0;
}
