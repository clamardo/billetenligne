import 'dart:io';

import 'package:bel_api/src/infrastructure/web/storefront_page.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:test/test.dart';

/// The storefront at `blt.cg/o/<code>` — the page an operator puts on a
/// poster.
///
/// The catalog the server actually ships, because half of what this page has
/// to get right is whether the sentence exists at all: a missing key renders
/// as a key on the one page a company shows the public.
final _catalog = CatalogLoader.fromDirectory(_i18nDirectory());

String _i18nDirectory() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_localization/i18n';
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('i18n directory not found from ${Directory.current.path}');
}

VitrineDto _vitrine({
  String? tradingName = 'Alizés',
  String accentHue = 'laterite',
  String headerPattern = 'diagonale',
  String? titleFr,
  String? taglineFr,
  String? logoUrl,
  String? coverUrl,
}) => VitrineDto(
  operatorId: 'op-1',
  code: 'ALZ',
  legalName: 'Alizés Transport SARL',
  tradingName: tradingName,
  accentHue: accentHue,
  headerPattern: headerPattern,
  titleFr: titleFr,
  taglineFr: taglineFr,
  logoUrl: logoUrl,
  coverUrl: coverUrl,
);

StorefrontRouteDto _route({
  String origin = 'Brazzaville',
  String destination = 'Dolisie',
  int fare = 9000,
  DateTime? next,
}) => StorefrontRouteDto(
  code: 'BZV-DOL',
  originCity: origin,
  destinationCity: destination,
  fromFare: Money.xaf(fare),
  nextDepartureAt: next,
);

String _render({
  VitrineDto? vitrine,
  List<StorefrontRouteDto>? routes,
  String language = 'fr',
  String origin = 'https://blt.cg',
}) => StorefrontPage.render(
  storefront: StorefrontDto(
    vitrine: vitrine ?? _vitrine(),
    routes: routes ?? [_route()],
  ),
  catalog: _catalog,
  language: language,
  origin: origin,
);

void main() {
  group('what a crawler sees', () {
    // The reader who matters most is the one building the WhatsApp preview
    // card, and it runs no JavaScript. Everything below has to be in the
    // first response or the link arrives in a group chat as a bare URL.
    test('the company is named in the markup, not fetched', () {
      final html = _render();
      expect(html, contains('<h1>Alizés</h1>'));
      expect(html, contains('Brazzaville → Dolisie'));
      // A narrow no-break space, which is what `Money.format` writes in
      // French — asserting a plain one would pass on the wrong string.
      expect(html, contains('9\u202f000'));
      expect(html, isNot(contains('fetch(')));
    });

    test('the card carries a title, a description and an image', () {
      final html = _render(
        vitrine: _vitrine(coverUrl: 'https://cdn.example/cover.png'),
      );
      expect(html, contains('property="og:title"'));
      expect(html, contains('property="og:description"'));
      expect(html, contains('content="https://cdn.example/cover.png"'));
    });

    test('with no cover the logo stands in, because a card with no image '
        'is a card nobody taps', () {
      final html = _render(
        vitrine: _vitrine(logoUrl: 'https://cdn.example/logo.png'),
      );
      expect(html, contains('content="https://cdn.example/logo.png"'));
    });

    test('this one is indexable, unlike the follower page', () {
      // A shop window that search engines cannot see is a shop window facing
      // a wall. The follower page is the opposite case and says so.
      expect(_render(), contains('content="index,follow"'));
    });
  });

  group('the company\'s own words and colours', () {
    test('their headline wins over their trading name', () {
      final html = _render(
        vitrine: _vitrine(titleFr: 'Alizés — Le confort du littoral'),
      );
      expect(html, contains('<h1>Alizés — Le confort du littoral</h1>'));
    });

    test('their tagline wins over ours', () {
      final html = _render(
        vitrine: _vitrine(taglineFr: 'Trente ans sur la nationale 1.'),
      );
      expect(html, contains('Trente ans sur la nationale 1.'));
      expect(html, isNot(contains('payez par mobile money')));
    });

    test('and ours is there when they have written nothing', () {
      // A company that has not described itself still gets a sentence, and
      // ours says what BilletEnLigne does rather than inventing a claim about
      // them.
      expect(_render(), contains('payez par mobile money'));
    });

    test('the accent is the hue they chose', () {
      expect(_render(), contains('--accent:#D9772F'));
      expect(_render(), contains('class="hero diagonale"'));
    });

    test('an accent nobody recognises renders the house green rather than '
        'a blank page', () {
      // The column has a CHECK constraint; if it ever disagrees with this
      // list the honest failure is a green header, not a white screen.
      final html = _render(vitrine: _vitrine(accentHue: 'chartreuse'));
      expect(html, contains('--accent:#0A6B4F'));
    });

    test('no logo draws the monogram the app draws', () {
      final html = _render(vitrine: _vitrine(tradingName: 'Océan du Nord'));
      expect(html, contains('class="logo mono">OD<'));
    });

    test('a one-word name gives one letter', () {
      final html = _render(vitrine: _vitrine(tradingName: 'Alizés'));
      expect(html, contains('class="logo mono">A<'));
    });
  });

  group('the lines they run', () {
    test('each links into the search already filled in', () {
      final html = _render(
        routes: [_route(origin: 'Pointe-Noire', destination: 'Dolisie')],
      );
      expect(html, contains('href="/?from=Pointe-Noire&to=Dolisie"'));
    });

    test('a city with a space survives the URL', () {
      final html = _render(routes: [_route(destination: 'Pointe Noire')]);
      expect(html, contains('to=Pointe+Noire'));
    });

    test('the next departure is Brazzaville time, not UTC', () {
      // UTC+1 and no daylight saving, so the offset is a constant rather than
      // a timezone database in a page this size.
      final html = _render(
        routes: [_route(next: DateTime.utc(2026, 8, 14, 5))],
      );
      expect(html, contains('14/08 06:00'));
    });

    test('a line with nothing scheduled says so rather than showing a blank',
        () {
      expect(_render(), contains('Aucun départ programmé'));
    });

    test('a company with no timetable is still a storefront', () {
      // They have chosen a colour and uploaded a logo; the page they put on a
      // poster must not be an error because the dispatcher has not published
      // next month yet.
      final html = _render(routes: const []);
      expect(html, contains("n'a pas encore publié"));
      expect(html, contains('<h1>Alizés</h1>'));
    });

    test('the footer says who is driving and who is charging', () {
      // The page wears the company's colours. Nobody must come away thinking
      // BilletEnLigne is the company, or that the company took the payment.
      expect(
        _render(),
        contains('Départs assurés par Alizés. '
            'Réservation et paiement par BilletEnLigne.'),
      );
    });
  });

  group('English, and the code that is not one', () {
    test('the whole page turns over', () {
      final html = _render(language: 'en');
      expect(html, contains('lang="en"'));
      expect(html, contains('Where we go'));
      expect(html, contains('See departures'));
      expect(html, contains('XAF 9,000'));
    });

    test('an unknown code and a suspended company read the same', () {
      // The reader cannot act on the difference, and telling them which one
      // it is would let anybody walk the code space to find out who we have
      // stopped.
      final html = StorefrontPage.notFound(catalog: _catalog);
      expect(html, contains("Cette vitrine n'existe pas"));
      expect(html, contains('Chercher un car'));
      // And it is not indexable: an error page in a search result is a
      // company that looks closed.
      expect(html, contains('content="noindex,nofollow"'));
    });
  });

  test('a name with a bracket in it cannot write markup', () {
    // The legal name comes from an application form somebody typed into.
    final html = _render(
      vitrine: _vitrine(tradingName: '<script>alert(1)</script>'),
    );
    expect(html, isNot(contains('<script>alert(1)')));
    expect(html, contains('&lt;script&gt;'));
  });
}
