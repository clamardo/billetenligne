import 'dart:convert';

import 'package:bel_localization/bel_localization.dart';

import 'artwork.g.dart';

/// The follower page: plain HTML and a little JavaScript (ADR-0014 §2).
///
/// **The one surface in this product where Flutter Web is the wrong tool**,
/// and ADR-0004 says so by name. The reader is a stranger on a random phone
/// on a random network who wants one answer — when should I leave for the
/// station — and a two-megabyte canvas payload to deliver it would be
/// indefensible. This is about six kilobytes, renders before it fetches
/// anything, and works on a browser that has never heard of us.
///
/// Four decisions worth writing down:
///
///   * **The words come from the same catalog as everything else** (ADR-0008).
///     A page with its sentences typed into a Dart string would be the one
///     place in the system where French lives somewhere other than
///     `bel_localization`, and it would drift within a month.
///   * **It is served, not built.** A `public/` directory would have to
///     survive `dart_frog build`, a container copy and a static host; a
///     constant in the binary survives all three by not depending on any of
///     them.
///   * **It polls, it does not socket.** Sixty seconds, matching the
///     endpoint's own cache header. A websocket for a page somebody watches
///     for ten minutes is battery and complexity for nothing.
///   * **A dead link says so kindly.** Revoked, expired and never-existed all
///     render the same sentence, because the follower cannot act on the
///     difference and the traveller did not ask to explain it.
abstract final class FollowerPage {
  static String render({
    required String token,
    required TranslationCatalog catalog,
    String language = 'fr',
    String apiBase = '',
  }) {
    final t = CatalogTranslator(catalog, language);

    // Injected as JSON rather than interpolated into the markup: every one of
    // these is prose that may contain an apostrophe, and a page that breaks
    // on "n'est plus valable" would break in French and nowhere else.
    final words = jsonEncode({
      'operator': t('follow.operator'),
      'departure': t('follow.departure'),
      'revised': t('follow.revised'),
      'arrival': t('follow.arrival'),
      'schedule': t('follow.tier.schedule'),
      'gps': t('follow.tier.gps'),
      'checkpoint': t('follow.tier.checkpoint'),
      'gone': t('follow.gone'),
      'goneBody': t('follow.goneBody'),
      'refreshed': t('follow.refreshed'),
      'privacy': t('follow.privacy'),
      'cta': t('follow.cta'),
      'status': {
        for (final s in const [
          'scheduled',
          'boarding',
          'departed',
          'arrived',
          'cancelled',
        ])
          s: t('follow.status.$s'),
      },
      'disrupted': t('follow.disrupted'),
      'disruptedNote': t('follow.disruptedNote'),
    });

    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(t('follow.title'))}</title>
<meta name="robots" content="noindex,nofollow">
<style>
:root{--ink:#141a17;--soft:#6b7a72;--line:#e2e8e4;--brand:#0f6b4f;--warn:#b26a00;--bg:#fbfcfb;
      --accent:#0f6b4f;--art-ink:#141a17;--art-muted:#6b7a72;--art-wash:#e9f1ec;
      --art-accent:#d9772f;--art-accent-wash:#fbeee2;--art-surface:#fff;
      --art-line:#e2e8e4}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
     font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:34rem;margin:0 auto;padding:1.5rem 1.25rem 3rem}
h1{font-size:1.5rem;margin:0 0 .25rem}
.sub{color:var(--soft);margin:0 0 1.5rem}
/* Inlined, not linked. This page is opened once, on a borrowed handset, on
   2G; a second request for the picture is the one that does not arrive. */
.art{max-width:12rem;margin:.25rem auto 1rem}
.art svg{width:100%;height:auto;display:block}
.card{background:#fff;border:1px solid var(--line);border-radius:12px;
      padding:1rem 1.1rem;margin-bottom:1rem}
.bar{height:8px;background:var(--line);border-radius:99px;overflow:hidden;margin:1rem 0 .5rem}
.bar>i{display:block;height:100%;background:var(--brand);width:0;
       transition:width .6s ease}
.ends{display:flex;justify-content:space-between;color:var(--soft);font-size:.85rem}
.tier{color:var(--soft);font-size:.85rem;margin-top:.75rem}
.est .bar>i{background:repeating-linear-gradient(90deg,var(--soft) 0 6px,transparent 6px 12px)}
.times{display:flex;justify-content:space-between;gap:1rem;margin-top:.75rem}
.times div{flex:1}
.k{color:var(--soft);font-size:.8rem;display:block}
.warn{border-color:#f0d9ae;background:#fdf6e9}
.warn h2{font-size:1rem;margin:0 0 .35rem;color:var(--warn)}
.warn p{margin:.25rem 0;font-size:.9rem}
.foot{color:var(--soft);font-size:.78rem;margin-top:1.5rem}
a.cta{display:block;text-align:center;margin-top:1.25rem;padding:.85rem;
      background:var(--brand);color:#fff;text-decoration:none;border-radius:10px}
@media(prefers-color-scheme:dark){
  :root{--ink:#e8efea;--soft:#93a49b;--line:#26312c;--bg:#0d1210;
        --accent:#3fbf8f;--art-ink:#e8efea;--art-muted:#93a49b;
        --art-wash:#122019;--art-accent:#f0a05c;--art-accent-wash:#2a1a0e;
        --art-surface:#161b18;--art-line:#26312c}
  .card{background:#131a17}
  .warn{background:#2a2008;border-color:#4a3a12}
}
</style>
</head>
<body>
<main>
  <div class="art" aria-hidden="true">${Artwork.css(Artwork.route)}</div>
  <h1 id="route">…</h1>
  <p class="sub" id="operator"></p>

  <div class="card" id="live" hidden>
    <div id="status"></div>
    <div class="bar"><i id="fill"></i></div>
    <div class="ends"><span id="from"></span><span id="to"></span></div>
    <div class="times">
      <div><span class="k" id="depK"></span><b id="dep"></b></div>
      <div><span class="k" id="arrK"></span><b id="arr"></b></div>
    </div>
    <div class="tier" id="tier"></div>
  </div>

  <div class="card warn" id="disruption" hidden>
    <h2 id="disruptionTitle"></h2>
    <p id="disruptionNote"></p>
  </div>

  <div class="card" id="gone" hidden>
    <h2 id="goneTitle" style="font-size:1rem;margin:0 0 .35rem"></h2>
    <p style="margin:0;font-size:.9rem" id="goneBody"></p>
  </div>

  <p class="foot" id="privacy"></p>
  <p class="foot" id="refreshed"></p>
  <a class="cta" href="/" id="cta"></a>
</main>
<script>
var W = $words;
var TOKEN = ${jsonEncode(token)};
var API = ${jsonEncode(apiBase)} + "/public/v1/trips/shared/" + encodeURIComponent(TOKEN);

function fill(node, text){ document.getElementById(node).textContent = text; }
function fmt(iso){
  // Brazzaville is UTC+1 and does not observe daylight saving, so the offset
  // is a constant rather than a timezone database in a 6 KB page.
  var d = new Date(iso);
  var h = ("0" + d.getUTCHours()).slice(-2), m = ("0" + d.getUTCMinutes()).slice(-2);
  var t = new Date(d.getTime() + 3600000);
  h = ("0" + t.getUTCHours()).slice(-2); m = ("0" + t.getUTCMinutes()).slice(-2);
  return h + ":" + m;
}
function sub(s, k, v){ return s.split("{" + k + "}").join(v); }

function dead(){
  document.getElementById("live").hidden = true;
  document.getElementById("disruption").hidden = true;
  document.getElementById("gone").hidden = false;
  fill("goneTitle", W.gone); fill("goneBody", W.goneBody);
  fill("route", W.gone);
  return null;
}

function paint(d){
  document.getElementById("gone").hidden = true;
  document.getElementById("live").hidden = false;

  fill("route", d.originCity + " \\u2192 " + d.destinationCity);
  fill("operator", sub(W.operator, "operator", d.operatorName));
  fill("from", d.originCity); fill("to", d.destinationCity);
  fill("status", W.status[d.status] || "");

  var when = d.revisedDepartsAt || d.departsAt;
  fill("depK", (d.revisedDepartsAt ? W.revised : W.departure).split(" {time}")[0]);
  fill("dep", fmt(when));
  fill("arrK", W.arrival.split(" {time}")[0]);
  fill("arr", fmt(d.arrivesAt));

  document.getElementById("fill").style.width =
    Math.round(d.progress * 100) + "%";
  document.getElementById("live").className =
    "card" + (d.tier === "schedule" ? " est" : "");

  if (d.tier === "checkpoint" && d.checkpointName) {
    fill("tier", sub(sub(W.checkpoint || "", "place", d.checkpointName),
                     "time", fmt(d.reportedAt)));
  } else if (d.tier === "gps" && d.reportedAt) {
    var mins = Math.max(0, Math.round((Date.now() - new Date(d.reportedAt)) / 60000));
    fill("tier", sub(W.gps || "", "minutes", mins));
  } else {
    fill("tier", W.schedule);
  }

  var box = document.getElementById("disruption");
  if (d.disruptionKind) {
    box.hidden = false;
    fill("disruptionTitle",
         sub(sub(W.disrupted, "kind", d.disruptionKind), "operator", d.operatorName));
    document.getElementById("disruptionNote").hidden = !d.disruptionNote;
    if (d.disruptionNote) {
      fill("disruptionNote", sub(W.disruptedNote, "note", d.disruptionNote));
    }
  } else { box.hidden = true; }

  fill("refreshed", sub(W.refreshed, "time", fmt(new Date().toISOString())));
}

function load(){
  fetch(API, {headers: {"Accept": "application/json"}})
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(d){ d ? paint(d) : dead(); })
    // A network blip must not blank a page somebody is reading. The last
    // painted state stays, and the "updated at" line is what tells them it
    // is going stale.
    .catch(function(){});
}

fill("privacy", W.privacy);
fill("cta", W.cta);
load();
setInterval(load, 60000);
</script>
</body>
</html>
''';
  }

  static String _attr(String value) =>
      value.replaceAll('"', '').replaceAll('<', '');

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
