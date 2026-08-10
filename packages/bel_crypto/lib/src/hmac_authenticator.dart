import 'package:bel_domain/bel_domain.dart';
import 'package:crypto/crypto.dart' as c;

/// HMAC-SHA256 for the rotating freshness code.
///
/// Synchronous on purpose: the domain computes a code for seven candidate time
/// windows on every scan (±90 s of clock tolerance), and an async call per
/// window would put a conductor's scan well over its two-second budget.
final class HmacSha256Authenticator implements MessageAuthenticator {
  const HmacSha256Authenticator();

  @override
  List<int> hmacSha256({required List<int> key, required List<int> message}) =>
      c.Hmac(c.sha256, key).convert(message).bytes;

  /// RFC 6238 and nothing else. The interoperability constraint is the whole
  /// reason: Google Authenticator, Aegis and 1Password compute HMAC-SHA1, and
  /// a stronger primitive nobody's phone implements is not a stronger control.
  @override
  List<int> hmacSha1({required List<int> key, required List<int> message}) =>
      c.Hmac(c.sha1, key).convert(message).bytes;
}
