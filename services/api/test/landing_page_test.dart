import 'dart:io';

import 'package:bel_api/src/infrastructure/web/landing_page.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:test/test.dart';

/// `blt.cg/` — the address on the poster.
///
/// Against the catalog the server actually ships, for the same reason the
/// storefront's tests are: a missing key on this page renders as a key on the
/// first thing a stranger ever sees of this product.
final _catalog = CatalogLoader.fromDirectory(_i18nDirectory());

String _i18nDirectory() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_localization/i18n';
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('i18n directory not found from ${Directory.current.path}');
}

void main() {
  String render({
    String language = 'fr',
    String? from,
    String? to,
    String? playStoreUrl,
    String? appStoreUrl,
    String consoleUrl = '',
  }) => LandingPage.render(
    catalog: _catalog,
    language: language,
    from: from,
    to: to,
    playStoreUrl: playStoreUrl,
    appStoreUrl: appStoreUrl,
    consoleUrl: consoleUrl,
  );

  group('what the page says', () {
    test('a whole document, in the language asked for', () {
      final html = render();
      expect(html, startsWith('<!doctype html>'));
      expect(html, contains('<html lang="fr">'));
      expect(html.trim(), endsWith('</html>'));
      expect(html, contains('Réservez votre place'));
    });

    test('english is a language, not a fallback to keys', () {
      final html = render(language: 'en');
      expect(html, contains('<html lang="en">'));
      expect(html, contains('Book your seat'));
      expect(html, isNot(contains('landing.')));
    });

    test('an unsupported language falls back rather than 500s', () {
      expect(render(language: 'de'), contains('<html lang="de">'));
      expect(render(language: 'de'), contains('Réservez votre place'));
    });

    test('the drawing is there, and is not a network request', () {
      final html = render();
      expect(html, contains('<svg'));
      expect(html, isNot(contains('<img')));
      // Inline, not fetched: this page is opened at the side of a road. The
      // one `http://` in it is the SVG namespace, which is an identifier and
      // not an address anything dials.
      expect(html, isNot(contains('src=')));
      expect(html, isNot(contains('href="http')));
    });

    test('it is small enough to open on a 2G connection', () {
      expect(render().length, lessThan(60 * 1024));
    });
  });

  group('the journey the link carried', () {
    test('both halves are said back, and the copy changes with them', () {
      final html = render(from: 'Brazzaville', to: 'Dolisie');
      expect(html, contains('Brazzaville'));
      expect(html, contains('Dolisie'));
      expect(html, contains('class="journey"'));
      expect(html, contains('Ce trajet vous attend'));
    });

    test('half a journey is no journey', () {
      // "Brazzaville →" is a page that lost the second half of the only fact
      // it was given, and reads worse than one that was told nothing.
      for (final half in [
        render(from: 'Brazzaville'),
        render(to: 'Dolisie'),
        render(from: '  ', to: 'Dolisie'),
      ]) {
        expect(half, isNot(contains('class="journey"')));
        expect(half, contains('Réservez votre place'));
      }
    });

    test('a journey somebody typed cannot close the tag it sits in', () {
      final html = render(from: '<script>alert(1)</script>', to: 'Dolisie');
      expect(html, isNot(contains('<script>alert')));
      expect(html, contains('&lt;script&gt;'));
    });
  });

  group('the store buttons', () {
    test('no listing means no button, and the page says why', () {
      final html = render();
      expect(html, isNot(contains('class="cta"')));
      expect(html, contains("n'est pas encore publiée"));
    });

    test('one listing means one button', () {
      final html = render(playStoreUrl: 'https://play.google.com/x');
      expect(html, contains('href="https://play.google.com/x"'));
      expect(html, contains('Sur Google Play'));
      expect(html, isNot(contains('App Store')));
      expect(html, isNot(contains("n'est pas encore publiée")));
    });

    test('both listings means both buttons, in install order', () {
      final html = render(
        playStoreUrl: 'https://play.google.com/x',
        appStoreUrl: 'https://apps.apple.com/y',
      );
      expect(
        html.indexOf('play.google.com'),
        lessThan(html.indexOf('apps.apple.com')),
      );
    });

    test('a console url is a link and a blank one is nothing at all', () {
      expect(render(), isNot(contains('class="ghost"')));
      expect(
        render(consoleUrl: 'https://console.blt.cg'),
        contains('href="https://console.blt.cg"'),
      );
    });

    test('a url with a quote in it cannot escape its attribute', () {
      final html = render(playStoreUrl: 'https://x/" onclick="evil()');
      expect(html, isNot(contains('onclick="evil')));
      expect(html, contains('&quot;'));
    });
  });
}
