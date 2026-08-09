import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:pointycastle/export.dart';

import 'jwt.dart';

/// RS256 — RSASSA-PKCS1-v1_5 over SHA-256.
///
/// Present for exactly one reason: **Firebase signs its ID tokens with it**
/// (ADR-0018), and we mint custom tokens the same way. Everything of ours is
/// Ed25519 (`Ed25519TicketVerifier`) because 64-byte signatures matter inside
/// a QR code; nothing here should be reached for by new code.
///
/// The DER identifier below is the SHA-256 `DigestInfo` prefix that
/// PKCS#1 v1.5 wraps the hash in. It is a constant of the standard, not a
/// choice.
const _sha256DigestIdentifier = '0609608648016503040201';

/// A public key in the form Google publishes it: the JWK endpoint hands back
/// `n` and `e` as base64url big-endian integers, which is one parse rather
/// than the X.509 certificate walk the other endpoint requires.
final class RsaPublicKey {
  RsaPublicKey(this.key, {this.keyId});

  final RSAPublicKey key;
  final String? keyId;

  factory RsaPublicKey.fromJwk(Map<String, Object?> jwk) {
    final n = jwk['n'];
    final e = jwk['e'];
    if (n is! String || e is! String) {
      throw const FormatException('JWK is missing n or e');
    }
    return RsaPublicKey(
      RSAPublicKey(
        _bigIntFromBytes(Jwt.base64UrlDecode(n, 'jwk.n')),
        _bigIntFromBytes(Jwt.base64UrlDecode(e, 'jwk.e')),
      ),
      keyId: jwk['kid'] as String?,
    );
  }
}

/// A service-account signing key, parsed from the PKCS#8 PEM that a Google
/// service-account JSON file carries in `private_key`.
///
/// **Server-side only.** No client ever holds one of these, in the same way
/// no device holds the Ed25519 ticket signing key.
final class RsaPrivateKey {
  RsaPrivateKey(this.key);

  final RSAPrivateKey key;

  /// Parses `-----BEGIN PRIVATE KEY-----` (PKCS#8). The other spelling,
  /// `BEGIN RSA PRIVATE KEY` (PKCS#1), is refused rather than guessed at:
  /// Google issues PKCS#8, and a silent fallback would mean a key of the
  /// wrong shape failing later, at signing time, in production.
  factory RsaPrivateKey.fromPkcs8Pem(String pem) {
    final body = pem
        .replaceAll(RegExp('-----(BEGIN|END) PRIVATE KEY-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    if (body.isEmpty) {
      throw const FormatException(
        'expected a PKCS#8 PEM (-----BEGIN PRIVATE KEY-----)',
      );
    }

    final outer = ASN1Parser(base64.decode(body)).nextObject();
    if (outer is! ASN1Sequence || outer.elements.length < 3) {
      throw const FormatException('not a PKCS#8 PrivateKeyInfo');
    }

    final wrapped = outer.elements[2];
    if (wrapped is! ASN1OctetString) {
      throw const FormatException('PrivateKeyInfo.privateKey is not an OCTET STRING');
    }

    // RSAPrivateKey ::= SEQUENCE { version, modulus, publicExponent,
    //   privateExponent, prime1, prime2, exponent1, exponent2, coefficient }
    final inner = ASN1Parser(wrapped.octets).nextObject();
    if (inner is! ASN1Sequence || inner.elements.length < 6) {
      throw const FormatException('not an RSAPrivateKey');
    }

    BigInt at(int i) {
      final element = inner.elements[i];
      if (element is! ASN1Integer) {
        throw FormatException('RSAPrivateKey field $i is not an INTEGER');
      }
      return element.valueAsBigInteger;
    }

    // pointycastle recomputes the CRT parameters from p and q, so the last
    // three fields are read past rather than trusted.
    return RsaPrivateKey(RSAPrivateKey(at(1), at(3), at(4), at(5)));
  }
}

/// Signs and verifies RS256. Both directions live together so the test that
/// proves one can prove the other against the same key.
final class RsaSha256 {
  const RsaSha256();

  Uint8List sign(Uint8List message, RsaPrivateKey key) {
    final signer = RSASigner(SHA256Digest(), _sha256DigestIdentifier)
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(key.key));
    return signer.generateSignature(message).bytes;
  }

  /// False rather than throwing, for every reason a signature can be wrong —
  /// including a malformed one. A verifier that throws on bad input is a
  /// verifier whose callers eventually wrap it in a bare `catch` that swallows
  /// the real failures too.
  bool verify(Uint8List message, Uint8List signature, RsaPublicKey key) {
    if (signature.isEmpty) return false;
    try {
      final signer = RSASigner(SHA256Digest(), _sha256DigestIdentifier)
        ..init(false, PublicKeyParameter<RSAPublicKey>(key.key));
      return signer.verifySignature(message, RSASignature(signature));
    } catch (_) {
      return false;
    }
  }
}

BigInt _bigIntFromBytes(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
