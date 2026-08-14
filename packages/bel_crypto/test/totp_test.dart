import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// TOTP, against the vectors in RFC 6238 Appendix B.
///
/// These live in `bel_crypto` rather than in `bel_domain` because the only
/// property worth asserting is **interoperability**, and that is a claim about
/// the real primitive: a fake MAC would let a wrong algorithm pass. If these
/// pass, the code on a reviewer's phone is the code the server expects.
void main() {
  const mac = HmacSha256Authenticator();

  // RFC 6238's SHA-1 seed: the ASCII string "12345678901234567890".
  final seed = List<int>.generate(20, (i) => 0x30 + ((i + 1) % 10));

  group('RFC 6238 Appendix B', () {
    // Time, then the expected 8-digit value. The RFC publishes eight digits;
    // we render six, which is the trailing six of the same number.
    const vectors = <int, String>{
      59: '94287082',
      1111111109: '07081804',
      1111111111: '14050471',
      1234567890: '89005924',
      2000000000: '69279037',
      20000000000: '65353130',
    };

    for (final entry in vectors.entries) {
      test('T=${entry.key} yields ${entry.value}', () {
        final counter = entry.key ~/ Totp.periodSeconds;
        expect(
          Totp.compute(secret: seed, counter: counter, mac: mac),
          entry.value.substring(entry.value.length - Totp.digits),
        );
      });
    }
  });

  group('verifying a presented code', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      1111111109 * 1000,
      isUtc: true,
    );

    test('the current code is accepted, and names its window', () {
      final code = Totp.compute(
        secret: seed,
        counter: Totp.windowAt(now),
        mac: mac,
      );

      // The window, not a bool: the caller has to record which one was spent
      // so the same code cannot be replayed inside its own thirty seconds.
      expect(
        Totp.windowOf(presented: code, secret: seed, now: now, mac: mac),
        Totp.windowAt(now),
      );
    });

    test('one window of drift is forgiven, two is not', () {
      final previous = Totp.compute(
        secret: seed,
        counter: Totp.windowAt(now) - 1,
        mac: mac,
      );
      final ancient = Totp.compute(
        secret: seed,
        counter: Totp.windowAt(now) - 2,
        mac: mac,
      );

      expect(
        Totp.windowOf(presented: previous, secret: seed, now: now, mac: mac),
        Totp.windowAt(now) - 1,
      );
      expect(
        Totp.windowOf(presented: ancient, secret: seed, now: now, mac: mac),
        isNull,
      );
    });

    test('a wrong code, a short code and a padded one are all refused', () {
      for (final presented in ['000000', '12345', ' 1234567 ', '']) {
        expect(
          Totp.windowOf(presented: presented, secret: seed, now: now, mac: mac),
          isNull,
          reason: presented,
        );
      }
    });

    test('spaces around a typed code are forgiven', () {
      final code = Totp.compute(
        secret: seed,
        counter: Totp.windowAt(now),
        mac: mac,
      );

      // People paste from a password manager, and password managers add
      // whitespace. Refusing that is refusing a correct code.
      expect(
        Totp.windowOf(presented: ' $code ', secret: seed, now: now, mac: mac),
        isNotNull,
      );
    });
  });

  group('base32, because an authenticator app has to read it', () {
    test('round-trips arbitrary secrets', () {
      for (var length = 1; length <= 32; length++) {
        final bytes = List<int>.generate(length, (i) => (i * 37 + 11) & 0xff);
        expect(Base32.decode(Base32.encode(bytes)), bytes, reason: '$length');
      }
    });

    test('matches the RFC 4648 vectors', () {
      expect(Base32.encode('foobar'.codeUnits), 'MZXW6YTBOI');
      expect(Base32.decode('MZXW6YTBOI'), 'foobar'.codeUnits);
    });

    test('tolerates what a human types', () {
      // Padding, lower case and the spaces an app inserts every four
      // characters. Refusing any of them is refusing a correct secret.
      expect(Base32.decode('mzxw 6ytb oi=='), 'foobar'.codeUnits);
    });

    test('a character outside the alphabet is nothing, not garbage', () {
      expect(Base32.decode('MZXW6YTB01'), isNull);
    });
  });

  test('the provisioning URI is what an app scans', () {
    final uri = Uri.parse(
      Totp.provisioningUri(
        secretBase32: 'JBSWY3DPEHPK3PXP',
        account: 'sarah@billetenligne.cg',
      ),
    );

    expect(uri.scheme, 'otpauth');
    expect(uri.host, 'totp');
    expect(uri.pathSegments.single, 'BilletEnLigne:sarah@billetenligne.cg');
    expect(uri.queryParameters['secret'], 'JBSWY3DPEHPK3PXP');
    expect(uri.queryParameters['issuer'], 'BilletEnLigne');
    // Stated rather than left to a default: the apps disagree about what the
    // default is, and a wrong assumption is six digits that never match.
    expect(uri.queryParameters['algorithm'], 'SHA1');
    expect(uri.queryParameters['period'], '30');
  });
}
