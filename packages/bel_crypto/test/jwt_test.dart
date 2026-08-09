import 'dart:convert';
import 'dart:typed_data';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:test/test.dart';

/// A throwaway 2048-bit key, generated once for this file and used nowhere
/// else. Fixed rather than generated per run so the suite stays in
/// milliseconds and a failure is reproducible — RSA key generation is the
/// slowest thing in this package by two orders of magnitude.
const _testPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDZ6X0cOoq0RAYs
sJDWsedyXFgKZ74nfGjpgPZFwlnhemoLyZbRedrL7EwQyXXgQqJJrtBwCZ/TfFyl
sokxOZAQQFeEPdcihl9Euc0hwb44772b8YpEs+ilQMQrInn33biVa2CtVmD4PR4g
Hn3wy3QI7vs6i132yRbqiUb7rHuI9WDl0YWqfy1AF5C7sPeIzGRZNtyB8OtUAflH
jkbqvKPl8Ew3tfLtHZ2suWqs1yTySbUNu0IVERXxHkK6Fc3Eyyc+yP12zMt48uJ/
nDiZ8KQgbdQqx5pg0tmP11fGNU4c468yWeaeH4PICcEScwbRhnPmZmmaOEHFoxy6
qMBETBADAgMBAAECggEAB6FTCL/evnfJTBuScDW2yY4cHuabIsq5RpzutwHJAubw
GHjuJ5bCwaiQdALu9kr6pavAfgmgPAC9/75lasDJdtGqqnbgx3Htg/atAW9z3BoP
1P7PwB68B18cJSdr2Ihsjjim5elvs7Rog9zDSMywZqt/L1MDgFIsU9ZRWL6OEEL4
k1y4uXDTwh3M5Q2R6QmFKQQHZy0lOHufhMX7kbgPmt4aX9Yk6Ai9kHJkfoK+8spv
7cfKDsH4joIfXUqw1mJ1G3nwQo2R+A9zCBqHAxPIoODsTUEkzfeblaDSbUgJQh5T
ut5jenmd1TU9kSzNOtFKyy9/ex8xLj24RikEJtBAGQKBgQDwVk4c+TjBeZsYLHkz
0pgcb5VZpBc2XYtFH7mX7zJ1X+Vzd5kNzOhfTGJ6KuM0UBpeyYYd8/OsHSmct48w
poRCLatf531PuAMSCqkHQjZvblT7IUz+OsbOdaNZVfIOMwxMuiyxpZ8Ns6IEWKCc
gth1Ngta9M6jpHeNxHED++KpSQKBgQDoHQ1cZJLCmqXGywgxuKF5W/OZ/KUnghxs
PNbKTpXNqz0q9H9T8ZnZBn6j8GI1mPqbQDfGloBDpaTrSBtADiy0dyaKAfhqQ9vr
3mqSd65aSa2e3C1j3Yyc9pyB4fwgiICs6ZjyxXAx+l0NgNIClKjV6XIkKdfIaZJ6
otoB3P9a6wKBgQC2AMW6z0kZy1uWXOeURSEIN8AkWE1z0DdNq47C7lOJ64s5fBKe
DtTShmf1GFFjJl4x9e7o8/tOFe+TTLbVIuT5sNgdEpMlMbaxjP0gEBZlIGqem0NR
K3WumAuR9bIO6r2fxUVfaosetzA0lmFa5QPDD6BdyxJJfp1C8MadO70UcQKBgQDc
p/GxqbKS6a065HxvuBNZaX6VHsZqXphilRujyz1B/c3ybeg1hvI4jKILe1QBm+Jx
gIUFdsGMjYXQXgX5yP/at4Kdo+3iJ4yEGDa78qZ/EpfI84r66vznotF577ldvCaH
OrK559QWzulzEsmSxnwSjxCBLH4D+cjUaMhTCSJ/7QKBgGvkvUQKoCJnUPxanPrg
RcRyCGDtR+Qwx/yHBzVtAHhMWd1uDfScDPqwY8wU4wHu4NHlu3FxBhwhUKZdKor8
KfufxXm/OZRYLKVZI2a9qQKoWsyBJie3t754n0Fa3UimdZzuvcgVFw/e8CtK5VRn
R0OLnp+uXQYDU27LYWiJvhIR
-----END PRIVATE KEY-----
''';

/// The same key as Google would publish it: `n` and `e`, base64url.
const _testJwk = <String, Object?>{
  'kid': 'test-key',
  'kty': 'RSA',
  'alg': 'RS256',
  'n':
      '2el9HDqKtEQGLLCQ1rHnclxYCme-J3xo6YD2RcJZ4XpqC8mW0Xnay-xMEMl14EKiSa7Qc'
      'Amf03xcpbKJMTmQEEBXhD3XIoZfRLnNIcG-OO-9m_GKRLPopUDEKyJ59924lWtgrVZg-D'
      '0eIB598Mt0CO77Ootd9skW6olG-6x7iPVg5dGFqn8tQBeQu7D3iMxkWTbcgfDrVAH5R45'
      'G6ryj5fBMN7Xy7R2drLlqrNck8km1DbtCFREV8R5CuhXNxMsnPsj9dszLePLif5w4mfCk'
      'IG3UKseaYNLZj9dXxjVOHOOvMlnmnh-DyAnBEnMG0YZz5mZpmjhBxaMcuqjAREwQAw',
  'e': 'AQAB',
};

String _segment(Map<String, Object?> value) =>
    Jwt.base64UrlEncode(utf8.encode(jsonEncode(value)));

/// Builds a signed token the way our custom-token minter does.
String _signedToken({
  Map<String, Object?> header = const {'alg': 'RS256', 'typ': 'JWT'},
  required Map<String, Object?> claims,
}) {
  final input = '${_segment(header)}.${_segment(claims)}';
  final signature = const RsaSha256().sign(
    Uint8List.fromList(ascii.encode(input)),
    RsaPrivateKey.fromPkcs8Pem(_testPrivateKeyPem),
  );
  return '$input.${Jwt.base64UrlEncode(signature)}';
}

void main() {
  group('Jwt.decode', () {
    test('reads the header, the claims and the signature material', () {
      final token = _signedToken(
        claims: {
          'sub': 'uid-42',
          'iss': 'https://securetoken.google.com/demo-billetenligne',
          'aud': 'demo-billetenligne',
          'exp': 1893456000,
          'iat': 1893452400,
        },
      );

      final jwt = Jwt.decode(token);

      expect(jwt.algorithm, 'RS256');
      expect(jwt.subject, 'uid-42');
      expect(jwt.issuer, 'https://securetoken.google.com/demo-billetenligne');
      expect(jwt.audience, ['demo-billetenligne']);
      expect(jwt.expiresAt, DateTime.utc(2030));
      expect(jwt.signature, isNotEmpty);
    });

    test('accepts an audience array as well as a string', () {
      final jwt = Jwt.decode(
        _signedToken(
          claims: {
            'aud': ['a', 'b'],
          },
        ),
      );
      expect(jwt.audience, ['a', 'b']);
    });

    test('signs over the bytes that arrived, not a re-encoding of them', () {
      // Two encodings of the same claims differ byte for byte — key order,
      // whitespace — and the signature is over one of them. A decoder that
      // rebuilt the signing input from its parsed map would verify tokens
      // nobody signed and reject tokens that are genuinely valid.
      final claims = {'sub': 'uid-1', 'iss': 'x'};
      final header = {'typ': 'JWT', 'alg': 'RS256'};
      final token = _signedToken(header: header, claims: claims);

      final jwt = Jwt.decode(token);
      expect(
        utf8.decode(jwt.signingInput),
        '${token.split('.')[0]}.${token.split('.')[1]}',
      );
    });

    test('an unsigned token parses, and carries an empty signature', () {
      // This is exactly what the Firebase emulator issues (ADR-0020). It has
      // to parse — otherwise local development cannot sign in at all — and it
      // has to be distinguishable, which is what the empty signature is for.
      final token = '${_segment({'alg': 'none', 'typ': 'JWT'})}'
          '.${_segment({'sub': 'uid-7'})}.';

      final jwt = Jwt.decode(token);
      expect(jwt.algorithm, 'none');
      expect(jwt.subject, 'uid-7');
      expect(jwt.signature, isEmpty);
    });

    test('refuses anything that is not three parts', () {
      expect(() => Jwt.decode('a.b'), throwsA(isA<JwtMalformed>()));
      expect(() => Jwt.decode('a.b.c.d'), throwsA(isA<JwtMalformed>()));
    });

    test('refuses a segment that is not base64url JSON', () {
      expect(() => Jwt.decode('!!!.b.c'), throwsA(isA<JwtMalformed>()));
      expect(
        () => Jwt.decode('${_segment({'alg': 'RS256'})}.${Jwt.base64UrlEncode(
          utf8.encode('["not","an","object"]'),
        )}.'),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('never puts the token in the failure', () {
      // A malformed bearer is still a bearer. One that reaches a log or a bug
      // report takes the next request's valid token with it.
      try {
        Jwt.decode('secret-looking-value');
        fail('expected JwtMalformed');
      } on JwtMalformed catch (e) {
        expect(e.toString(), isNot(contains('secret-looking-value')));
      }
    });
  });

  group('RS256', () {
    final rsa = const RsaSha256();
    final publicKey = RsaPublicKey.fromJwk(_testJwk);

    test('a signature made with the private key verifies against the JWK', () {
      final token = _signedToken(claims: {'sub': 'uid-42'});
      final jwt = Jwt.decode(token);

      expect(rsa.verify(jwt.signingInput, jwt.signature, publicKey), isTrue);
    });

    test('a tampered payload does not verify', () {
      final token = _signedToken(claims: {'sub': 'uid-42'});
      final parts = token.split('.');
      final forged =
          '${parts[0]}.${_segment({'sub': 'uid-admin'})}.${parts[2]}';

      final jwt = Jwt.decode(forged);
      expect(jwt.subject, 'uid-admin');
      expect(rsa.verify(jwt.signingInput, jwt.signature, publicKey), isFalse);
    });

    test('an unsigned token never verifies', () {
      // The `alg: none` attack: strip the signature, keep the claims. The
      // empty signature has to be a refusal here even though it is a legal
      // parse above, because the only thing that may accept one is the
      // explicitly emulator-only path.
      final jwt = Jwt.decode(
        '${_segment({'alg': 'none'})}.${_segment({'sub': 'uid-admin'})}.',
      );
      expect(rsa.verify(jwt.signingInput, jwt.signature, publicKey), isFalse);
    });

    test('a malformed signature is false, not an exception', () {
      expect(
        rsa.verify(
          Uint8List.fromList(ascii.encode('anything')),
          Uint8List.fromList([1, 2, 3]),
          publicKey,
        ),
        isFalse,
      );
    });

    test('refuses a PEM of the wrong shape rather than guessing', () {
      expect(
        () => RsaPrivateKey.fromPkcs8Pem(
          '-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
