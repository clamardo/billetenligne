import 'dart:convert';
import 'dart:typed_data';

import 'package:bel_api/src/adapters/firebase_auth_gateway.dart';
import 'package:bel_api/src/application/ports/user_directory.dart';
import 'package:bel_api/src/infrastructure/memory/memory_identity.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

const _privateKeyPem = '''
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

const _jwk = <String, Object?>{
  'kid': 'google-key-1',
  'n':
      '2el9HDqKtEQGLLCQ1rHnclxYCme-J3xo6YD2RcJZ4XpqC8mW0Xnay-xMEMl14EKiSa7Qc'
      'Amf03xcpbKJMTmQEEBXhD3XIoZfRLnNIcG-OO-9m_GKRLPopUDEKyJ59924lWtgrVZg-D'
      '0eIB598Mt0CO77Ootd9skW6olG-6x7iPVg5dGFqn8tQBeQu7D3iMxkWTbcgfDrVAH5R45'
      'G6ryj5fBMN7Xy7R2drLlqrNck8km1DbtCFREV8R5CuhXNxMsnPsj9dszLePLif5w4mfCk'
      'IG3UKseaYNLZj9dXxjVOHOOvMlnmnh-DyAnBEnMG0YZz5mZpmjhBxaMcuqjAREwQAw',
  'e': 'AQAB',
};

/// Stands in for Google's JWK endpoint, so signature verification can be
/// proven without reaching the network.
final class StubKeys implements FirebasePublicKeys {
  StubKeys(this._keys);
  final Map<String, RsaPublicKey> _keys;

  @override
  Future<RsaPublicKey?> forKeyId(String keyId) async => _keys[keyId];
}

final class FixedClock implements Clock {
  const FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

void main() {
  final now = DateTime.utc(2026, 8, 9, 6);
  const projectId = 'billetenligne-prod';

  String segment(Map<String, Object?> value) =>
      Jwt.base64UrlEncode(utf8.encode(jsonEncode(value)));

  int epoch(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

  Map<String, Object?> goodClaims({
    String uid = 'uid-aline',
    String? issuer,
    Object? audience,
    DateTime? expiresAt,
    bool withAuthTime = true,
  }) => {
    'sub': uid,
    'iss': issuer ?? 'https://securetoken.google.com/$projectId',
    'aud': audience ?? projectId,
    'iat': epoch(now.subtract(const Duration(minutes: 1))),
    'exp': epoch(expiresAt ?? now.add(const Duration(hours: 1))),
    if (withAuthTime)
      'auth_time': epoch(now.subtract(const Duration(minutes: 1))),
  };

  String signed(Map<String, Object?> claims, {String kid = 'google-key-1'}) {
    final header = segment({'alg': 'RS256', 'typ': 'JWT', 'kid': kid});
    final body = segment(claims);
    final signature = const RsaSha256().sign(
      Uint8List.fromList(ascii.encode('$header.$body')),
      RsaPrivateKey.fromPkcs8Pem(_privateKeyPem),
    );
    return '$header.$body.${Jwt.base64UrlEncode(signature)}';
  }

  String unsigned(Map<String, Object?> claims) =>
      '${segment({'alg': 'none', 'typ': 'JWT'})}.${segment(claims)}.';

  late MemoryUserDirectory directory;

  FirebaseAuthGateway production() => FirebaseAuthGateway(
    config: const FirebaseConfig(projectId: projectId),
    directory: directory,
    publicKeys: StubKeys({'google-key-1': RsaPublicKey.fromJwk(_jwk)}),
    clock: FixedClock(now),
  );

  FirebaseAuthGateway emulator() => FirebaseAuthGateway(
    config: const FirebaseConfig(
      projectId: projectId,
      emulatorHost: 'localhost:9099',
    ),
    directory: directory,
    publicKeys: StubKeys(const {}),
    clock: FixedClock(now),
  );

  setUp(() {
    directory = MemoryUserDirectory(clock: FixedClock(now));
    directory.seed(
      const Account(
        id: 'u-aline',
        authUid: 'uid-aline',
        email: 'aline@example.cg',
        language: 'fr',
      ),
    );
  });

  group('verifying an ID token in production', () {
    test('a genuine token resolves to our own account', () async {
      final principal = await production().verify(signed(goodClaims()));

      expect(principal, isNotNull);
      // Firebase said who; our database said which row. The user id is ours,
      // never Firebase's (ADR-0018).
      expect(principal!.userId, 'u-aline');
      expect(principal.authUid, 'uid-aline');
      expect(principal.language, 'fr');
    });

    test('an unsigned token is refused', () async {
      // The `alg: none` bypass. This single assertion is the difference
      // between an authenticated API and an open one.
      expect(await production().verify(unsigned(goodClaims())), isNull);
    });

    test('a token signed with an unknown key is refused', () async {
      expect(
        await production().verify(signed(goodClaims(), kid: 'not-googles')),
        isNull,
      );
    });

    test('a tampered subject is refused', () async {
      final token = signed(goodClaims());
      final parts = token.split('.');
      final forged =
          '${parts[0]}.${segment(goodClaims(uid: 'uid-somebody-else'))}'
          '.${parts[2]}';

      expect(await production().verify(forged), isNull);
    });

    test("another project's token is refused", () async {
      // A valid, Google-signed token — for somebody else's Firebase project.
      // Without the issuer and audience checks this verifies perfectly and
      // hands a stranger an account.
      expect(
        await production().verify(
          signed(goodClaims(issuer: 'https://securetoken.google.com/other')),
        ),
        isNull,
      );
      expect(
        await production().verify(signed(goodClaims(audience: 'other-app'))),
        isNull,
      );
    });

    test('an expired token is refused', () async {
      expect(
        await production().verify(
          signed(
            goodClaims(expiresAt: now.subtract(const Duration(minutes: 1))),
          ),
        ),
        isNull,
      );
    });

    test('a custom token presented as a bearer is refused', () async {
      // A custom token is a credential to be *exchanged* with Firebase, not
      // one to be presented to us. It has no auth_time, which is how they are
      // told apart — and accepting one would let anybody who intercepted the
      // sign-in response skip Firebase entirely.
      expect(
        await production().verify(signed(goodClaims(withAuthTime: false))),
        isNull,
      );
    });

    test('garbage is refused without throwing', () async {
      expect(await production().verify('not-a-token'), isNull);
      expect(await production().verify(''), isNull);
    });
  });

  group('the database is the authority, not the token', () {
    test('a valid token for an unknown user is anonymous', () async {
      final principal = await production().verify(
        signed(goodClaims(uid: 'uid-nobody')),
      );
      expect(principal, isNull);
    });

    test('a valid token for a disabled account is refused', () async {
      // Firebase will keep vouching for them until somebody remembers to
      // disable them there too. The account row is what decides.
      directory.seed(
        Account(
          id: 'u-aline',
          authUid: 'uid-aline',
          email: 'aline@example.cg',
          language: 'fr',
          disabledAt: now,
        ),
      );

      expect(await production().verify(signed(goodClaims())), isNull);
    });
  });

  group('against the emulator', () {
    test('an unsigned token is accepted', () async {
      // Which is the only way a credential-free local loop can work — and is
      // why the branch is gated on FIREBASE_AUTH_EMULATOR_HOST rather than on
      // the token saying it is unsigned.
      final principal = await emulator().verify(unsigned(goodClaims()));
      expect(principal?.userId, 'u-aline');
    });

    test("but somebody else's project still is not", () async {
      expect(
        await emulator().verify(
          unsigned(goodClaims(issuer: 'https://securetoken.google.com/other')),
        ),
        isNull,
      );
    });
  });

  group('minting a custom token', () {
    test('carries the uid Firebase will hand back, and expires', () async {
      final token = await emulator().mintCustomToken(uid: 'u-aline');
      final decoded = Jwt.decode(token);

      expect(decoded.claims['uid'], 'u-aline');
      expect(
        decoded.audience.single,
        contains('identitytoolkit.googleapis.com'),
      );
      expect(decoded.expiresAt, now.add(const Duration(hours: 1)));
      // No auth_time: this is not an ID token and must not be usable as one.
      expect(decoded.authenticatedAt, isNull);
    });

    test('is signed when a service-account key is configured', () async {
      final gateway = FirebaseAuthGateway(
        config: const FirebaseConfig(
          projectId: projectId,
          serviceAccountEmail: 'sa@billetenligne.iam.gserviceaccount.com',
          privateKeyPem: _privateKeyPem,
        ),
        directory: directory,
        publicKeys: StubKeys(const {}),
        clock: FixedClock(now),
      );

      final decoded = Jwt.decode(await gateway.mintCustomToken(uid: 'u-aline'));

      expect(decoded.algorithm, 'RS256');
      expect(decoded.issuer, 'sa@billetenligne.iam.gserviceaccount.com');
      expect(
        const RsaSha256().verify(
          decoded.signingInput,
          decoded.signature,
          RsaPublicKey.fromJwk(_jwk),
        ),
        isTrue,
      );
    });

    test(
      'a conductor token carries its scope as a hint, not as authority',
      () async {
        final decoded = Jwt.decode(
          await emulator().mintConductorToken(
            staffUserId: 'staff-1',
            operatorId: 'op-ocean',
            departureIds: const ['dep-1', 'dep-2'],
            ttl: const Duration(hours: 8),
          ),
        );

        final claims = decoded.claims['claims']! as Map<String, Object?>;
        expect(claims['tenantId'], 'op-ocean');
        expect(claims['roles'], ['conductor']);
        expect(claims['departures'], ['dep-1', 'dep-2']);
        expect(decoded.expiresAt, now.add(const Duration(hours: 8)));
      },
    );
  });

  test('the private key survives a service-account JSON round trip', () {
    // Service-account JSON escapes the newlines. A PEM whose line breaks are
    // the two characters `\` and `n` parses as garbage, and the exception it
    // throws names ASN.1 rather than the environment variable that caused it.
    final config = FirebaseConfig.fromEnvironment({
      'FIREBASE_PROJECT_ID': projectId,
      'FIREBASE_PRIVATE_KEY': _privateKeyPem.replaceAll('\n', r'\n'),
    });

    expect(
      () => RsaPrivateKey.fromPkcs8Pem(config.privateKeyPem!),
      returnsNormally,
    );
    expect(config.usingEmulator, isFalse);
  });
}
