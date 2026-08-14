import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_localization/bel_localization.dart';

import 'artwork.g.dart';
import 'accent_hues.dart';

/// The public storefront at `blt.cg/o/<code>` (`03-operator-lifecycle.md`
/// §2.4).
///
/// The JSON behind it has existed since the vitrine shipped, and nothing had
/// ever rendered it — so an operator who chose a colour, a pattern, a logo and
/// a cover had no address to put on a poster. This is that address.
///
/// **Rendered whole on the server, not fetched like the follower page.** The
/// two pages look like the same problem and are not. A follower has already
/// opened a link somebody sent them and is waiting for a coach to move; this
/// page exists *to be shared*, and the reader who matters most is the WhatsApp
/// crawler that builds the preview card. That crawler runs no JavaScript. A
/// page that painted itself after a fetch would arrive in a group chat as a
/// bare URL with no name, no cover and no reason to tap — which is the whole
/// job.
///
/// Three more decisions worth the ink:
///
///   * **It is indexable.** The follower page carries `noindex` because it is
///     about one person's journey. This one is a shop window: an operator
///     searching for their own company should find it, and so should somebody
///     searching for a coach to Dolisie.
///   * **The company's colours, in our layout.** The accent and the header
///     pattern come from `AccentHue` and the same three vectors the console
///     previews, so the poster and the app agree. What does not move is the
///     structure — a storefront that could be laid out freely would become a
///     page where the fare is in eight-point grey.
///   * **Every line links into the search already filled in.** Somebody who
///     tapped *Brazzaville → Dolisie* has said where they are going, and
///     landing them on a home page to say it again is how a sales channel
///     turns back into a brochure.
abstract final class StorefrontPage {
  /// The page for an operator that sells.
  ///
  /// [origin] is this deployment's own base URL, used only for the absolute
  /// URLs Open Graph requires — a relative `og:image` is ignored by every
  /// crawler that reads it.
  static String render({
    required StorefrontDto storefront,
    required TranslationCatalog catalog,
    String language = 'fr',
    String origin = '',
  }) {
    final t = CatalogTranslator(catalog, language);
    final v = storefront.vitrine;
    // The operator's own headline if they wrote one, in the reader's language
    // if they wrote it — `titleFor` already falls through to the trading name
    // and then the legal one, so this is never empty.
    final name = v.titleFor(language);
    final accent = AccentHues.hex(v.accentHue);
    final title = t('storefront.title', {'operator': name});
    // And their own sentence about themselves, if they have one. Ours says
    // what BilletEnLigne does, which is the right thing to say about a company
    // that has not yet said anything about itself.
    final tagline = v.taglineFor(language) ?? t('storefront.tagline');

    final head = StringBuffer()
      ..writeln('<title>${_text(title)}</title>')
      ..writeln('<meta name="description" content="${_attr(tagline)}">')
      // Indexable, unlike the follower page. See the class doc.
      ..writeln('<meta name="robots" content="index,follow">')
      ..writeln('<meta property="og:type" content="website">')
      ..writeln('<meta property="og:title" content="${_attr(title)}">')
      ..writeln(
        '<meta property="og:description" content="'
        '${_attr(tagline)}">',
      );

    // The cover if there is one, the logo if there is not. A card with no
    // image is a card people scroll past, and the logo at least carries the
    // company's colours.
    final social = v.coverUrl ?? v.logoUrl;
    if (social != null) {
      head.writeln(
        '<meta property="og:image" content="'
        '${_attr(_absolute(social, origin))}">',
      );
    }

    return _document(
      language: language,
      accent: accent,
      head: head.toString(),
      body: _body(storefront: storefront, t: t, name: name, tagline: tagline),
    );
  }

  /// A code nobody issued, and a company that has stopped selling. The same
  /// page for both, deliberately: the reader cannot act on the difference,
  /// and telling them which one it is would let anybody walk the code space
  /// to find out who we have suspended.
  static String notFound({
    required TranslationCatalog catalog,
    String language = 'fr',
  }) {
    final t = CatalogTranslator(catalog, language);
    return _document(
      language: language,
      accent: AccentHues.hex(null),
      head:
          '<title>${_text(t('storefront.unknown'))}</title>\n'
          '<meta name="robots" content="noindex,nofollow">',
      body:
          '''
  <main class="narrow">
    <div class="art" aria-hidden="true">${Artwork.css(Artwork.searchEmpty)}</div>
    <h1>${_text(t('storefront.unknown'))}</h1>
    <p class="sub">${_text(t('storefront.unknownBody'))}</p>
    <a class="cta" href="/">${_text(t('storefront.search'))}</a>
  </main>''',
    );
  }

  static String _body({
    required StorefrontDto storefront,
    required CatalogTranslator t,
    required String name,
    required String tagline,
  }) {
    final v = storefront.vitrine;
    final buffer = StringBuffer();

    buffer.writeln('  <header class="hero ${_attr(v.headerPattern)}">');
    if (v.coverUrl != null) {
      buffer.writeln(
        '    <img class="cover" src="${_attr(v.coverUrl!)}" '
        'alt="" aria-hidden="true">',
      );
    } else {
      // No photograph, so the header used to be a rectangle of flat colour
      // with a pattern over it. The drawing is inlined rather than linked:
      // this page has to be a shop window in the first response, and a
      // separate request for the one thing that makes it look like a shop is
      // the request most likely not to arrive.
      //
      // It renders as a silhouette because `.hero` overrides `--art-brand` —
      // the company's own colour is already the background here.
      buffer.writeln(
        '    <div class="scene" aria-hidden="true">'
        '${_cover(Artwork.css(Artwork.journey))}</div>',
      );
    }
    buffer.writeln('    <div class="heroInner">');
    if (v.logoUrl != null) {
      buffer.writeln(
        '      <img class="logo" src="${_attr(v.logoUrl!)}" '
        'alt="${_attr(name)}">',
      );
    } else {
      // The console promises this in as many words — *aucune vitrine ne reste
      // vide* — so the fallback is the same monogram `KMonogram` draws, not a
      // grey square.
      buffer.writeln(
        '      <div class="logo mono">${_text(_initials(name))}'
        '</div>',
      );
    }
    buffer
      ..writeln('      <h1>${_text(name)}</h1>')
      ..writeln('      <p class="tagline">${_text(tagline)}</p>')
      ..writeln('    </div>')
      ..writeln('  </header>')
      ..writeln('  <main>');

    if (storefront.routes.isEmpty) {
      buffer
        ..writeln(
          '    <div class="art" aria-hidden="true">'
          '${Artwork.css(Artwork.noTrips)}</div>',
        )
        ..writeln('    <p class="sub">${_text(t('storefront.empty'))}</p>');
    } else {
      buffer.writeln('    <h2>${_text(t('storefront.routes'))}</h2>');
      buffer.writeln('    <ul class="routes">');
      for (final route in storefront.routes) {
        buffer.write(_route(route, t));
      }
      buffer.writeln('    </ul>');
    }

    buffer
      ..writeln(
        '    <p class="foot">'
        '${_text(t('storefront.operated', {'operator': name}))}</p>',
      )
      ..writeln('  </main>');
    return buffer.toString();
  }

  static String _route(StorefrontRouteDto route, CatalogTranslator t) {
    final where = '${route.originCity} → ${route.destinationCity}';
    final fare = t('storefront.from', {
      'price': route.fromFare.format(locale: t.language),
    });
    final when = route.nextDepartureAt == null
        ? t('storefront.noneToday')
        : t('storefront.next', {'when': _when(route.nextDepartureAt!)});

    // Into the search, already filled in — see the class doc. City names
    // rather than ids, because that is what somebody editing the URL would
    // type and what a poster's QR code should survive being reprinted with.
    //
    // **`/` is a landing page and never a booking portal.** It reads the two
    // parameters and says the journey back, so somebody who tapped
    // *Brazzaville → Dolisie* is not started over; the booking itself happens
    // in the app, which is where the seat map, the offline ticket and the
    // rotating QR live. The follower page's own call to action has pointed at
    // `/` since it shipped, for the same reason — the address is the
    // decision, and it had to be right on a poster printed before the page
    // existed.
    final href =
        '/?from=${Uri.encodeQueryComponent(route.originCity)}'
        '&to=${Uri.encodeQueryComponent(route.destinationCity)}';

    return '''
      <li>
        <a href="${_attr(href)}">
          <span class="where">${_text(where)}</span>
          <span class="when">${_text(when)}</span>
          <span class="fare">${_text(fare)}</span>
          <span class="go">${_text(t('storefront.book'))}</span>
        </a>
      </li>
''';
  }

  /// Brazzaville is UTC+1 and does not observe daylight saving, so the offset
  /// is a constant rather than a timezone database in a page this size — the
  /// same trade the follower page makes, for the same reason.
  static String _when(DateTime utc) {
    final local = utc.add(const Duration(hours: 1));
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final mo = local.month.toString().padLeft(2, '0');
    return '$dd/$mo $hh:$mm';
  }

  /// Up to two letters, from up to two words. The same rule `KMonogram` uses,
  /// so the fallback logo here and the one in the app are the same mark.
  static String _initials(String name) {
    final words = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words.first.substring(0, 1).toUpperCase();
    }
    return (words[0].substring(0, 1) + words[1].substring(0, 1)).toUpperCase();
  }

  /// Open Graph wants an absolute URL. A storage URL already is one; a
  /// relative asset path only happens when the in-memory store is serving,
  /// which is a local run — and a crawler is not reading those.
  static String _absolute(String url, String origin) =>
      url.startsWith('http') ? url : '$origin$url';

  static String _document({
    required String language,
    required String accent,
    required String head,
    required String body,
  }) =>
      '''
<!doctype html>
<html lang="${_attr(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="$accent">
$head
<style>
:root{--accent:$accent;--ink:#141a17;--soft:#6b7a72;--line:#e2e8e4;--bg:#fbfcfb;
      --art-ink:#141a17;--art-muted:#6b7a72;--art-wash:#e9f1ec;
      --art-accent:#d9772f;--art-accent-wash:#fbeee2;--art-surface:#fff;
      --art-line:#e2e8e4}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
     font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:36rem;margin:0 auto;padding:1.5rem 1.25rem 3rem}
main.narrow{padding-top:4rem;text-align:center}
h1{font-size:1.6rem;margin:0}
h2{font-size:1rem;color:var(--soft);font-weight:600;margin:0 0 .75rem;
   text-transform:uppercase;letter-spacing:.04em}
.sub{color:var(--soft)}
.hero{position:relative;background:var(--accent);color:#fff;overflow:hidden;
      /* The drawing turns into a silhouette here: the company's colour is
         already the ground, so hills painted in it would be invisible. */
      --art-brand:rgba(255,255,255,.34);--art-wash:rgba(0,0,0,.20);
      --art-ink:rgba(0,0,0,.5);--art-muted:rgba(255,255,255,.55);
      --art-surface:rgba(255,255,255,.9);--art-accent:rgba(255,255,255,.5);
      --art-accent-wash:rgba(255,255,255,.26);
      --art-line:rgba(255,255,255,.3)}
.hero .cover{position:absolute;inset:0;width:100%;height:100%;
             object-fit:cover;opacity:.55}
.hero .scene{position:absolute;inset:0}
.hero .scene svg{width:100%;height:100%;display:block}
.art{margin:1.5rem auto 1rem;max-width:15rem}
.art svg{width:100%;height:auto;display:block}
/* The two generated vectors, drawn in CSS rather than shipped as files: a
   storefront must render before anything else has loaded. */
.hero.diagonale:after{content:"";position:absolute;inset:0;
  background:repeating-linear-gradient(135deg,rgba(255,255,255,.10) 0 12px,
                                        transparent 12px 28px)}
.hero.vagues:after{content:"";position:absolute;inset:0;
  background:radial-gradient(120% 60% at 50% 120%,rgba(255,255,255,.16),
                             transparent 60%)}
.heroInner{position:relative;max-width:36rem;margin:0 auto;
           padding:2.25rem 1.25rem 2rem}
.logo{width:64px;height:64px;border-radius:14px;object-fit:cover;
      background:#fff;display:block;margin-bottom:.9rem}
.logo.mono{display:flex;align-items:center;justify-content:center;
           color:var(--accent);font-size:1.5rem;font-weight:700}
.tagline{margin:.4rem 0 0;opacity:.92}
.routes{list-style:none;margin:0;padding:0}
.routes li{margin-bottom:.6rem}
.routes a{display:grid;grid-template-columns:1fr auto;gap:.15rem .75rem;
          background:#fff;border:1px solid var(--line);border-radius:12px;
          padding:.9rem 1rem;text-decoration:none;color:inherit}
.where{font-weight:600}
.when{color:var(--soft);font-size:.85rem}
.fare{grid-column:2;grid-row:1;text-align:right;font-weight:600;
      color:var(--accent);white-space:nowrap}
.go{grid-column:2;grid-row:2;text-align:right;color:var(--soft);
    font-size:.85rem;white-space:nowrap}
.foot{color:var(--soft);font-size:.8rem;margin-top:2rem}
a.cta{display:inline-block;margin-top:1.5rem;padding:.85rem 1.5rem;
      background:var(--accent);color:#fff;text-decoration:none;
      border-radius:10px}
@media(prefers-color-scheme:dark){
  :root{--ink:#e8efea;--soft:#93a49b;--line:#26312c;--bg:#0d1210;
        --art-ink:#e8efea;--art-muted:#93a49b;--art-wash:#122019;
        --art-accent:#f0a05c;--art-accent-wash:#2a1a0e;--art-surface:#161b18;
        --art-line:#26312c}
  .routes a{background:#131a17}
}
</style>
</head>
<body>
$body
</body>
</html>
''';

  /// Crops the drawing to the header rather than letterboxing it. The
  /// default is `meet`, which would leave bands of flat colour above and
  /// below on any header that is not exactly the artwork's proportions —
  /// which is every header, since the height comes from the text on it.
  static String _cover(String svg) =>
      svg.replaceFirst('<svg ', '<svg preserveAspectRatio="xMidYMid slice" ');

  static String _attr(String value) =>
      value.replaceAll('"', '&quot;').replaceAll('<', '&lt;');

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
