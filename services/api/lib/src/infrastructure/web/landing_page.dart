import 'package:bel_localization/bel_localization.dart';

import 'accent_hues.dart';
import 'artwork.g.dart';

/// `blt.cg/` — the address on the poster.
///
/// This is where somebody lands who scans the QR on the side of a coach,
/// types what they read on a wall, or taps *voir les départs* on an
/// operator's storefront. Until this file existed, that address answered
/// `{"service":"billetenligne","status":"ok"}`, which is a sentence written
/// for a monitoring probe and read by a person standing at a bus station.
///
/// Three decisions worth writing down.
///
///   * **It is not a booking portal, and it never becomes one.** A traveller
///     web portal is on the list of things this product deliberately does not
///     build (`09-roadmap.md`): the seat map, the offline ticket and the
///     rotating QR are the reasons the app exists, and none of them survives
///     being a web page. So this says what BilletEnLigne is, where to get the
///     app, and stops.
///   * **It answers the journey it was asked about.** The storefront's route
///     links carry `?from=&to=`, because somebody who tapped
///     *Brazzaville → Dolisie* has already said where they are going. A page
///     that drops that on the floor reads as having lost the thread.
///   * **It does not show a store button that goes nowhere.** No listing is
///     published. A dead link on the first page a stranger ever sees is the
///     fastest way to lose them for good, so the buttons appear only when a
///     deployment has actually been given a store URL, and otherwise the page
///     says the app is not out yet in as many words.
///
/// Self-contained and small, like the follower page and for the same reason:
/// the reader is on a phone on a 2G connection, and half of them arrived from
/// a link in WhatsApp.
abstract final class LandingPage {
  static String render({
    required TranslationCatalog catalog,
    String language = 'fr',
    String? from,
    String? to,
    String? playStoreUrl,
    String? appStoreUrl,
    String consoleUrl = '',
  }) {
    final t = CatalogTranslator(catalog, language);
    final accent = AccentHues.hex(null);

    // Both halves, or neither. A page that says "Brazzaville ->" has lost the
    // second half of the only fact it was given.
    final origin = from?.trim() ?? '';
    final destination = to?.trim() ?? '';
    final hasJourney = origin.isNotEmpty && destination.isNotEmpty;

    final journeyHtml = hasJourney
        ? '<p class="journey">'
              '${_text(t('landing.route', {'from': origin, 'to': destination}))}'
              '</p>'
        : '';

    final stores = <(String, String)>[
      if (playStoreUrl != null && playStoreUrl.isNotEmpty)
        (playStoreUrl, t('landing.playStore')),
      if (appStoreUrl != null && appStoreUrl.isNotEmpty)
        (appStoreUrl, t('landing.appStore')),
    ];

    final appCard = StringBuffer('<div class="card">')
      ..write(
        '<h2>'
        '${_text(t(stores.isEmpty ? 'landing.notPublished' : 'landing.getApp'))}'
        '</h2>',
      );
    if (stores.isEmpty) {
      appCard.write('<p>${_text(t('landing.notPublishedBody'))}</p>');
    }
    for (final store in stores) {
      appCard.write(
        '<a class="cta" href="${_attr(store.$1)}">${_text(store.$2)}</a>',
      );
    }
    appCard.write('</div>');

    final consoleLink = consoleUrl.isEmpty
        ? ''
        : '<a class="ghost" href="${_attr(consoleUrl)}">'
              '${_text(t('landing.consoleCta'))}</a>';

    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(t('landing.title'))}</title>
<meta name="description" content="${_attr(t('landing.tagline'))}">
<meta property="og:title" content="${_attr(t('landing.title'))}">
<meta property="og:description" content="${_attr(t('landing.tagline'))}">
<meta property="og:type" content="website">
<style>
:root{--ink:#141a17;--soft:#6b7a72;--line:#e2e8e4;--accent:$accent;
      --bg:#fbfcfb;--card:#ffffff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
     font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:34rem;margin:0 auto;padding:0 0 3rem}
.hero{position:relative;background:var(--accent);color:#fff;overflow:hidden;
      padding:2.5rem 1.25rem 2.75rem;
      /* The drawing turns into a silhouette here: the ground is already the
         house colour, so hills painted in it would be invisible. The same
         eight overrides the storefront's own hero uses. */
      --art-brand:rgba(255,255,255,.34);--art-wash:rgba(0,0,0,.20);
      --art-ink:rgba(0,0,0,.5);--art-muted:rgba(255,255,255,.55);
      --art-surface:rgba(255,255,255,.9);--art-accent:rgba(255,255,255,.5);
      --art-accent-wash:rgba(255,255,255,.26);
      --art-line:rgba(255,255,255,.3)}
.hero .scene{position:absolute;inset:0;opacity:.9}
.hero .scene svg{width:100%;height:100%;display:block;object-fit:cover}
.heroInner{position:relative}
h1{font-size:1.6rem;line-height:1.25;margin:0}
.tag{margin:.5rem 0 0;color:rgba(255,255,255,.92)}
.journey{display:inline-block;margin:0 0 .75rem;padding:.3rem .7rem;
         border-radius:999px;background:rgba(255,255,255,.18);
         font-weight:600;font-size:.95rem}
.wrap{padding:1.25rem}
ul.what{list-style:none;margin:0 0 1.5rem;padding:0}
ul.what li{position:relative;padding:.45rem 0 .45rem 1.6rem}
ul.what li:before{content:"";position:absolute;left:.2rem;top:1.05rem;
                  width:.5rem;height:.5rem;border-radius:50%;
                  background:var(--accent)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
      padding:1.1rem;margin-bottom:1rem}
.card h2{font-size:1.05rem;margin:0 0 .35rem}
.card p{margin:0;color:var(--soft);font-size:.92rem}
a.cta{display:block;text-align:center;margin-top:.6rem;padding:.85rem;
      background:var(--accent);color:#fff;text-decoration:none;
      border-radius:10px;font-weight:600}
a.ghost{display:block;text-align:center;margin-top:.6rem;padding:.8rem;
        border:1px solid var(--line);border-radius:10px;
        color:var(--ink);text-decoration:none}
.foot{color:var(--soft);font-size:.8rem;text-align:center;margin-top:1.5rem}
@media(prefers-color-scheme:dark){
  :root{--ink:#e8efea;--soft:#93a49b;--line:#26312c;--bg:#0d1210;--card:#131a17}
}
</style>
</head>
<body>
<main>
  <header class="hero">
    <div class="scene" aria-hidden="true">${Artwork.css(Artwork.journey)}</div>
    <div class="heroInner">
      $journeyHtml
      <h1>${_text(t('landing.title'))}</h1>
      <p class="tag">${_text(hasJourney ? t('landing.routeNote') : t('landing.tagline'))}</p>
    </div>
  </header>

  <div class="wrap">
    <ul class="what">
      <li>${_text(t('landing.what1'))}</li>
      <li>${_text(t('landing.what2'))}</li>
      <li>${_text(t('landing.what3'))}</li>
    </ul>

    $appCard

    <div class="card">
      <h2>${_text(t('landing.operators'))}</h2>
      <p>${_text(t('landing.operatorsBody'))}</p>
      $consoleLink
    </div>

    <p class="foot">${_text(t('landing.footer'))}</p>
  </div>
</main>
</body>
</html>
''';
  }

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _attr(String value) => _text(value).replaceAll('"', '&quot;');
}
