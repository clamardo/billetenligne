import 'dart:io';

/// The cookie a browser session travels in (J11).
///
/// Four attributes, and each one is load-bearing:
///
///   * **`HttpOnly`** — script in the page cannot read it. This is the whole
///     point: an XSS against a page holding a refresh token in `localStorage`
///     is a ninety-day account takeover, and the same XSS against a cookie it
///     cannot read costs whatever can be done from inside that page while it
///     is open.
///   * **`Secure`** — never sent in the clear. Unconditional rather than
///     configurable: browsers treat `localhost` as a secure context and accept
///     `Secure` cookies there, so a development knob would buy nothing and
///     would be the knob that eventually ships.
///   * **`SameSite=Lax`** — a cross-*site* request never carries it, which is
///     what makes CSRF a non-issue without a token of its own. The console on
///     `console.blt.cg` calling `blt.cg` is a different *origin* and the same
///     *site*, so it still works; a form on somebody else's domain does not.
///   * **`Path=/`** — every surface, one session.
///
/// [domain] is configuration and is normally set (`BEL__COOKIEDOMAIN=blt.cg`)
/// so the console, the back office and the public surface share one session.
/// Unset it is a host-only cookie, which is right for a local stack where
/// everything is `localhost`.
final class SessionCookie {
  const SessionCookie({this.name = 'bel_session', this.domain});

  final String name;
  final String? domain;

  static SessionCookie fromEnvironment(Map<String, String> env) =>
      SessionCookie(domain: _blank(env['BEL__COOKIEDOMAIN']));

  /// The `Set-Cookie` value for a session that has just opened.
  String issue(String selector, {required Duration ttl}) => _build(
    value: selector,
    maxAge: ttl.inSeconds,
  );

  /// The `Set-Cookie` value that ends one.
  ///
  /// An empty value with `Max-Age=0`, and every other attribute identical: a
  /// browser matches a deletion to an existing cookie by name, domain and
  /// path, so a clear that differs in any of them leaves the original in
  /// place and the person stays signed in.
  String clear() => _build(value: '', maxAge: 0);

  String _build({required String value, required int maxAge}) => [
    '$name=$value',
    'Path=/',
    if (domain != null) 'Domain=$domain',
    'Max-Age=$maxAge',
    'HttpOnly',
    'Secure',
    'SameSite=Lax',
  ].join('; ');

  /// The selector a request carries, or null.
  ///
  /// Parsed here rather than with `HttpHeaders` because Dart Frog hands over a
  /// flattened header map. Cookie values here are base64url, so nothing needs
  /// unquoting — and a value with anything else in it is not one we minted.
  String? read(Map<String, String> headers) {
    final raw = headers[HttpHeaders.cookieHeader];
    if (raw == null || raw.isEmpty) return null;

    for (final pair in raw.split(';')) {
      final at = pair.indexOf('=');
      if (at <= 0) continue;
      if (pair.substring(0, at).trim() != name) continue;
      final value = pair.substring(at + 1).trim();
      return _isSelector(value) ? value : null;
    }
    return null;
  }

  /// Base64url, 1–128 characters. A guard rather than validation: it keeps a
  /// header somebody hand-wrote out of a database lookup, and costs nothing.
  static bool _isSelector(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static String? _blank(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
