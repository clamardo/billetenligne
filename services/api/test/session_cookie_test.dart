import 'dart:io';

import 'package:bel_api/src/middleware/session_cookie.dart';
import 'package:test/test.dart';

/// The cookie a browser session travels in (J11).
///
/// Every assertion here is about an attribute, and every attribute is the
/// whole of a control: drop `HttpOnly` and an XSS reads the session, drop
/// `SameSite` and any page on the internet can spend it, drop `Secure` and a
/// café network can.
void main() {
  const cookie = SessionCookie();

  group('what is set', () {
    test('the four attributes that make this safe at all', () {
      final header = cookie.issue('abc123', ttl: const Duration(days: 30));

      expect(header, startsWith('bel_session=abc123'));
      // Script in the page cannot read it. This is the difference between an
      // XSS costing a session and an XSS costing ninety days.
      expect(header, contains('HttpOnly'));
      // Never in the clear. Unconditional: browsers treat localhost as a
      // secure context, so a development knob would buy nothing and would be
      // the knob that eventually ships.
      expect(header, contains('Secure'));
      // A cross-*site* request never carries it, which is what makes CSRF a
      // non-issue without a token of its own.
      expect(header, contains('SameSite=Lax'));
      expect(header, contains('Path=/'));
      expect(header, contains('Max-Age=2592000'));
    });

    test('a domain is set only when the deployment names one', () {
      // Host-only is right for a local stack where everything is localhost.
      expect(cookie.issue('abc', ttl: Duration.zero), isNot(contains('Domain')));

      const shared = SessionCookie(domain: 'blt.cg');
      // And named in production, so the console, the back office and the
      // public surface are one session rather than three.
      expect(
        shared.issue('abc', ttl: Duration.zero),
        contains('Domain=blt.cg'),
      );
    });

    test('the value carries no bearer and no refresh token', () {
      // The selector is opaque and random. Everything that is actually a
      // credential stays on the server — that is the whole slice.
      final header = cookie.issue('SELECTOR', ttl: const Duration(days: 30));

      expect(header, isNot(contains('.')), reason: 'a JWT has dots');
      expect(header.toLowerCase(), isNot(contains('bearer')));
      expect(header.toLowerCase(), isNot(contains('refresh')));
    });
  });

  group('what is cleared', () {
    test('a deletion matches the cookie it deletes', () {
      final gone = cookie.clear();

      // A browser matches a deletion by name, domain and path. One that
      // differed in any of them would leave the original in place and the
      // person signed in.
      expect(gone, startsWith('bel_session='));
      expect(gone, contains('Max-Age=0'));
      expect(gone, contains('Path=/'));
      expect(gone, contains('HttpOnly'));
      expect(gone, contains('SameSite=Lax'));
    });

    test('and keeps the domain when there is one', () {
      const shared = SessionCookie(domain: 'blt.cg');
      expect(shared.clear(), contains('Domain=blt.cg'));
    });
  });

  group('what is read', () {
    String? read(String header) =>
        cookie.read({HttpHeaders.cookieHeader: header});

    test('one cookie among several', () {
      expect(read('theme=dark; bel_session=abc123; lang=fr'), 'abc123');
      expect(read('bel_session=abc123'), 'abc123');
    });

    test('no cookie at all is nobody, not an error', () {
      expect(cookie.read(const {}), isNull);
      expect(read(''), isNull);
      expect(read('theme=dark'), isNull);
    });

    test('a name that merely ends the same way is a different cookie', () {
      // `not_bel_session` must not resolve a session. Suffix matching here
      // would let any subdomain that can set a cookie name one of ours.
      expect(read('not_bel_session=abc123'), isNull);
      expect(read('bel_session_old=abc123'), isNull);
    });

    test('a value we could not have minted is not looked up', () {
      // A guard rather than validation: it keeps a hand-written header out of
      // a database round trip, and costs nothing.
      expect(read('bel_session=has spaces'), isNull);
      expect(read('bel_session="quoted"'), isNull);
      expect(read('bel_session=${'x' * 200}'), isNull);
      expect(read('bel_session='), isNull);
    });
  });
}
