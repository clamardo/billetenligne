import 'package:bel_api/src/middleware/request_headers.dart';
import 'package:test/test.dart';

void main() {
  group('header lookup is case-insensitive', () {
    // The server normalises header names to lowercase. Reading them with the
    // canonical casing returns null, which is how conditional GET silently
    // stopped working — caught only by running the real server.
    test('finds a header whatever case the server used', () {
      const headers = {'if-none-match': '"abc"'};
      expect(headers.header('If-None-Match'), '"abc"');
      expect(headers.header('if-none-match'), '"abc"');
      expect(headers.header('IF-NONE-MATCH'), '"abc"');
    });

    test('returns null when genuinely absent', () {
      expect(const <String, String>{}.header('If-None-Match'), isNull);
    });
  });

  group('ETag matching', () {
    test('matches an exact tag', () {
      expect(const {'if-none-match': '"abc"'}.matchesEtag('"abc"'), isTrue);
    });

    test('does not match a different tag', () {
      expect(const {'if-none-match': '"abc"'}.matchesEtag('"xyz"'), isFalse);
    });

    test('tolerates the weak prefix a proxy may add', () {
      expect(const {'if-none-match': 'W/"abc"'}.matchesEtag('"abc"'), isTrue);
      expect(const {'if-none-match': '"abc"'}.matchesEtag('W/"abc"'), isTrue);
    });

    test('handles a comma-separated list', () {
      expect(
        const {'if-none-match': '"old", "abc", "older"'}.matchesEtag('"abc"'),
        isTrue,
      );
    });

    test('honours the wildcard', () {
      expect(const {'if-none-match': '*'}.matchesEtag('"anything"'), isTrue);
    });

    test('an absent or blank header never matches', () {
      expect(const <String, String>{}.matchesEtag('"abc"'), isFalse);
      expect(const {'if-none-match': ''}.matchesEtag('"abc"'), isFalse);
    });
  });
}
