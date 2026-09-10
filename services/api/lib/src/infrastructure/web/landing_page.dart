import 'package:bel_localization/bel_localization.dart';

import 'accent_hues.dart';
import 'artwork.g.dart';
import 'weave.dart';

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
    // The paper's own cloth, and the same weave again on the closing band in
    // white. One motif, two grounds — the app does exactly this.
    final weave = Weave.image('#1d5c46', opacity: 0.05);
    final weaveOnGreen = Weave.image('#ffffff', opacity: 0.12);

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
      --bg:#f6f4ee;--card:#ffffff;--measure:34rem}
*{box-sizing:border-box}
/* Three bands, and the middle one takes the slack. A poster fills the wall
   it is on: before this, the page was a 34rem column that simply stopped,
   and every viewport taller than the content ended in a field of white. */
html{background:var(--accent)}
body{margin:0;min-height:100dvh;display:flex;flex-direction:column;
     background:var(--bg);color:var(--ink);
     font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.band{padding-inline:1.25rem}
/* The measure applies to the words, never to the artwork: `.scene` is a
   child of the hero and was being clamped to 44rem with it, which left the
   drawing as a rectangle floating in a flat green field. */
.band>*:not(.scene){max-width:var(--measure);margin-inline:auto}
.hero{position:relative;background:var(--accent);color:#fff;overflow:hidden;
      /* Enough band for the drawing to be a drawing. Below this the road and
         the coach are a stripe. */
      min-height:min(20rem,46dvh);display:flex;align-items:center;
      padding-block:3rem 5rem;
      /* The drawing turns into a silhouette here: the ground is already the
         house colour, so hills painted in it would be invisible. The same
         eight overrides the storefront's own hero uses. */
      --art-brand:rgba(255,255,255,.34);--art-wash:rgba(0,0,0,.20);
      --art-ink:rgba(0,0,0,.5);--art-muted:rgba(255,255,255,.55);
      --art-surface:rgba(255,255,255,.9);--art-accent:rgba(255,255,255,.5);
      --art-accent-wash:rgba(255,255,255,.26);
      --art-line:rgba(255,255,255,.3)}
/* `preserveAspectRatio`, not `object-fit`: an inline <svg> ignores the
   latter, which is why the road used to be sliced off mid-drawing at the
   bottom of the band. */
.hero .scene{position:absolute;inset:0;max-width:none;opacity:.92}
.hero .scene svg{width:100%;height:100%;display:block}
/* The same scrim `KScene` paints behind text in the apps. Without it the
   headline sits on whatever part of the drawing the crop happens to put
   under it, and the contrast is a matter of luck. */
.hero:before{content:"";position:absolute;inset:0;
             background:linear-gradient(180deg,
               rgba(9,42,32,.55) 0%,rgba(9,42,32,.28) 55%,rgba(9,42,32,0) 100%)}
.heroInner{position:relative;width:100%}
h1{font-size:clamp(1.6rem,1.1rem + 2.2vw,2.6rem);line-height:1.2;margin:0;
   letter-spacing:-.01em}
.tag{margin:.6rem 0 0;color:rgba(255,255,255,.92);max-width:30rem}
.journey{display:inline-block;margin:0 0 .85rem;padding:.3rem .7rem;
         border-radius:999px;background:rgba(255,255,255,.18);
         font-weight:600;font-size:.95rem}
/* The paper, with the app's own cloth on it. Faint on purpose — it should
   read as texture at arm's length and as nothing at all under body text. */
/* Centred in whatever height is left over. Five elements on a desktop
   viewport pooled at the top and left two thirds of the page empty; the same
   five, centred, read as a composed page at every height the poster is
   opened at. */
/* 44px rather than the tile's own 68: at full size the weave reads as
   wallpaper on a desktop and competes with the words. Small and faint, it is
   the cloth you notice only once you look for it. */
.wrap{flex:1;display:flex;align-items:center;padding-block:3rem;
      background-image:$weave;background-size:44px 44px;
      background-position:center}
ul.what{list-style:none;margin:0 0 1.75rem;padding:0;display:grid;gap:.25rem}
ul.what li{position:relative;padding:.45rem 0 .45rem 1.6rem}
ul.what li:before{content:"";position:absolute;left:.2rem;top:1.05rem;
                  width:.5rem;height:.5rem;border-radius:50%;
                  background:var(--accent)}
.cards{display:grid;gap:1rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;
      padding:1.15rem}
.card h2{font-size:1.05rem;margin:0 0 .35rem}
.card p{margin:0;color:var(--soft);font-size:.92rem}
a.cta{display:block;text-align:center;margin-top:.7rem;padding:.85rem;
      background:var(--accent);color:#fff;text-decoration:none;
      border-radius:10px;font-weight:600}
a.ghost{display:block;text-align:center;margin-top:.7rem;padding:.8rem;
        border:1px solid var(--line);border-radius:10px;
        color:var(--ink);text-decoration:none}
/* The page ends on the house colour rather than trailing off. It also means
   a viewport taller than the content shows cloth, never a white sheet. */
.foot{background:var(--accent);color:rgba(255,255,255,.86);font-size:.85rem;
      padding-block:1.6rem;background-image:$weaveOnGreen;
      background-size:44px 44px}
/* Block margins only. `margin:0` here used to cancel the `margin-inline:auto`
   that centres everything else on the page, and dropped the line to the far
   left of a wide screen. */
.foot p{margin-block:0}
@media(min-width:52rem){
  :root{--measure:44rem}
  ul.what{grid-template-columns:repeat(3,1fr);gap:1.25rem}
  ul.what li{padding:.6rem 0 0 0;border-top:2px solid var(--accent)}
  ul.what li:before{display:none}
  .cards{grid-template-columns:1fr 1fr;align-items:start}
}
@media(prefers-color-scheme:dark){
  :root{--ink:#e8efea;--soft:#93a49b;--line:#26312c;--bg:#101715;--card:#161e1b}
}
</style>
</head>
<body>
  <header class="hero band">
    <div class="scene" aria-hidden="true">${_cover(Artwork.css(Artwork.journey))}</div>
    <div class="heroInner">
      $journeyHtml
      <h1>${_text(t('landing.title'))}</h1>
      <p class="tag">${_text(hasJourney ? t('landing.routeNote') : t('landing.tagline'))}</p>
    </div>
  </header>

  <main class="wrap band">
    <div>
      <ul class="what">
        <li>${_text(t('landing.what1'))}</li>
        <li>${_text(t('landing.what2'))}</li>
        <li>${_text(t('landing.what3'))}</li>
      </ul>

      <div class="cards">
        $appCard
        <div class="card">
          <h2>${_text(t('landing.operators'))}</h2>
          <p>${_text(t('landing.operatorsBody'))}</p>
          $consoleLink
        </div>
      </div>
    </div>
  </main>

  <footer class="foot band">
    <p>${_text(t('landing.footer'))}</p>
  </footer>
</body>
</html>
''';
  }

  /// Fill the band rather than letter-box inside it. An inline `<svg>`
  /// ignores `object-fit`, which is what sliced the road off mid-drawing at
  /// the bottom of the hero; `preserveAspectRatio` is the attribute that
  /// actually crops it. The storefront's hero keeps the same rule.
  static String _cover(String svg) => svg.replaceFirst(
    '<svg ',
    // `YMax`, not `YMid`. These scenes are drawn with the horizon high and
    // the road, the coach and the ground along the bottom edge; cropping
    // from the centre cuts the coach in half and keeps the sky.
    '<svg preserveAspectRatio="xMidYMax slice" ',
  );

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _attr(String value) => _text(value).replaceAll('"', '&quot;');
}
