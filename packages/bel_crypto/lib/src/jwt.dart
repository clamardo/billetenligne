import 'dart:convert';
import 'dart:typed_data';

/// A JWT that would not parse. Never carries the token itself: a malformed
/// bearer is still a bearer, and putting one in a log or an error message is
/// how a valid token from the *next* request ends up in a bug report.
final class JwtMalformed implements Exception {
  const JwtMalformed(this.reason);
  final String reason;

  @override
  String toString() => 'JwtMalformed: $reason';
}

/// A decoded, **not yet verified**, JSON Web Token.
///
/// Decoding and verifying are deliberately separate types of work. Anything
/// that reads a claim off one of these before checking the signature has
/// trusted an attacker's JSON, so the signature material stays attached —
/// [signingInput] and [signature] — rather than being discarded at parse time.
final class Jwt {
  const Jwt._({
    required this.header,
    required this.claims,
    required this.signingInput,
    required this.signature,
  });

  final Map<String, Object?> header;
  final Map<String, Object?> claims;

  /// `base64url(header).base64url(payload)`, as bytes. Exactly what was
  /// signed — recomputed from the original text rather than re-encoded from
  /// the parsed maps, because re-encoding does not round-trip and the
  /// signature is over the bytes that arrived.
  final Uint8List signingInput;

  final Uint8List signature;

  /// The algorithm the token *claims*. A hint for key selection and nothing
  /// more: the caller decides which algorithm is acceptable, never the token.
  /// Trusting this field is the classic JWT vulnerability — a token that says
  /// `alg: none` verifies against nothing at all.
  String get algorithm => header['alg'] as String? ?? '';

  /// The key the issuer says it signed with, for rotation.
  String? get keyId => header['kid'] as String?;

  String? get subject => claims['sub'] as String?;
  String? get issuer => claims['iss'] as String?;

  /// `aud` is a string or an array of strings in the spec, and Firebase uses
  /// the string form — but a verifier that only handles one shape fails
  /// mysteriously the day the other arrives.
  List<String> get audience => switch (claims['aud']) {
    final String single => [single],
    final List<Object?> many => many.whereType<String>().toList(),
    _ => const [],
  };

  DateTime? get expiresAt => _time('exp');
  DateTime? get issuedAt => _time('iat');
  DateTime? get authenticatedAt => _time('auth_time');

  DateTime? _time(String key) {
    final value = claims[key];
    if (value is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      value.toInt() * 1000,
      isUtc: true,
    );
  }

  static Jwt decode(String token) {
    final parts = token.split('.');
    if (parts.length != 3) {
      throw JwtMalformed('expected 3 dot-separated parts, got ${parts.length}');
    }

    return Jwt._(
      header: _decodeSegment(parts[0], 'header'),
      claims: _decodeSegment(parts[1], 'payload'),
      signingInput: Uint8List.fromList(
        ascii.encode('${parts[0]}.${parts[1]}'),
      ),
      // An empty third part is legal and is what the Firebase emulator
      // produces (ADR-0020). It is not a parse failure; it is a token that
      // will fail every signature check that is not explicitly unsigned.
      signature: parts[2].isEmpty
          ? Uint8List(0)
          : base64UrlDecode(parts[2], 'signature'),
    );
  }

  static Map<String, Object?> _decodeSegment(String segment, String what) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64UrlDecode(segment, what)));
    } on FormatException catch (e) {
      throw JwtMalformed('$what is not JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw JwtMalformed('$what is not an object');
    }
    return decoded;
  }

  /// Base64url without padding, which is what JWT uses and what
  /// `base64Url.decode` refuses.
  static Uint8List base64UrlDecode(String input, [String what = 'segment']) {
    try {
      return base64Url.decode(input.padRight((input.length + 3) & ~3, '='));
    } on FormatException catch (e) {
      throw JwtMalformed('$what is not base64url: ${e.message}');
    }
  }

  static String base64UrlEncode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
