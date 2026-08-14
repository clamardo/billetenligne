import 'package:bel_api/src/infrastructure/web/web_origins.dart';
import 'package:test/test.dart';

/// Which browser origins may call this API.
///
/// The list itself is small enough to read; these tests are about the two
/// ways a list like this goes wrong — a wildcard nobody meant, and a mismatch
/// on punctuation that refuses a deployment for a trailing slash.
void main() {
  group('reading the variable', () {
    test('a comma-separated list, and the whitespace does not count', () {
      final origins = WebOrigins.from({
        'BEL__WEBORIGINS': 'https://console.blt.cg, https://admin.blt.cg',
      });
      expect(origins.allows('https://console.blt.cg'), isTrue);
      expect(origins.allows('https://admin.blt.cg'), isTrue);
    });

    test('unset means nobody, which is a working state', () {
      // The handset apps and the scanner are not browsers and send no
      // `Origin` at all, so an API with no list serves them as before.
      final origins = WebOrigins.from(const {});
      expect(origins.isEmpty, isTrue);
      expect(origins.allows('https://console.blt.cg'), isFalse);
      expect(origins.allows(null), isFalse);
    });

    test('an empty entry is not an origin', () {
      final origins = WebOrigins.from({'BEL__WEBORIGINS': ',,  ,'});
      expect(origins.isEmpty, isTrue);
      expect(origins.allows(''), isFalse);
    });
  });

  group('matching', () {
    final origins = WebOrigins(const [
      'https://console.blt.cg/',
      'http://localhost:5000',
    ]);

    test('a trailing slash on either side is the same origin', () {
      expect(origins.allows('https://console.blt.cg'), isTrue);
      expect(origins.allows('https://console.blt.cg/'), isTrue);
    });

    test('and so is a capital letter somebody typed', () {
      expect(origins.allows('https://Console.BLT.cg'), isTrue);
    });

    test('the scheme is part of the origin', () {
      // `http://console.blt.cg` is a different origin to the browser and must
      // be one here: allowing the plain-HTTP twin of an HTTPS console is how
      // a token ends up on the wire.
      expect(origins.allows('http://console.blt.cg'), isFalse);
    });

    test('the port is part of the origin', () {
      expect(origins.allows('http://localhost:5001'), isFalse);
    });

    test('a subdomain of an allowed origin is not allowed', () {
      expect(origins.allows('https://evil.console.blt.cg'), isFalse);
    });

    test('and neither is a name that merely starts the same', () {
      expect(origins.allows('https://console.blt.cg.evil.com'), isFalse);
    });

    test('there is no wildcard, and nothing spells one', () {
      final wild = WebOrigins.from({'BEL__WEBORIGINS': '*'});
      expect(wild.allows('https://anything.example'), isFalse);
      expect(wild.allows('*'), isTrue, reason: 'only the literal string');
    });
  });
}
