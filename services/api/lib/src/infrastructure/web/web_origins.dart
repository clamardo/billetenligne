/// The origins a browser may call this API from.
///
/// **Why this exists.** The operator console and the back office are Flutter
/// web apps, and until the day they became images nothing had ever served
/// them from anywhere but a `flutter run`. Building them made the gap
/// impossible to miss: a bundle on `console.blt.cg` calling an API on
/// `blt.cg` is a cross-origin request, and this API had never sent an
/// `Access-Control-Allow-Origin` header in its life. The browser blocks it
/// before the request leaves — which is every deployment of those two images,
/// and `flutter run -d chrome` on `localhost:5000` as well.
///
/// **An allow-list, never a wildcard.** `*` is the one-line version and it is
/// wrong here for a specific reason: every interesting route on this API is
/// behind a bearer token, and a wildcard invites any page on the internet to
/// try one — a token pasted into the wrong tab, an XSS on an unrelated site,
/// a phishing page that asks a dispatcher to sign in. The list is
/// configuration (`BEL__WEBORIGINS`), it is empty by default, and empty means
/// no cross-origin browser may call this API at all.
///
/// **The echo is exact.** An allowed origin is echoed back verbatim, because
/// a browser compares the header to its own origin character for character;
/// an unknown one is not echoed and not mentioned. Nothing is derived from
/// the request but the lookup key, which is the whole reason a reflected-CORS
/// bug is not possible here.
final class WebOrigins {
  WebOrigins(Iterable<String> allowed)
    : allowed = {
        for (final origin in allowed)
          if (normalize(origin).isNotEmpty) normalize(origin),
      };

  /// `BEL__WEBORIGINS=https://console.blt.cg,https://admin.blt.cg`.
  ///
  /// Empty is the default and is a working state: the handset apps and the
  /// scanner are not browsers and never send an `Origin`, so an API with no
  /// list configured serves them exactly as before.
  factory WebOrigins.from(Map<String, String> env) =>
      WebOrigins((env['BEL__WEBORIGINS'] ?? '').split(','));

  final Set<String> allowed;

  bool get isEmpty => allowed.isEmpty;

  /// Whether [origin] — the raw header — may be echoed back.
  bool allows(String? origin) =>
      origin != null && allowed.contains(normalize(origin));

  /// Scheme and authority, lower-cased, with no trailing slash.
  ///
  /// `https://Console.BLT.cg/` and `https://console.blt.cg` are the same
  /// origin; a set that disagrees would refuse a deployment for a capital
  /// letter in a config file, at the exact moment nobody is looking at the
  /// config file.
  static String normalize(String origin) {
    var value = origin.trim().toLowerCase();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
