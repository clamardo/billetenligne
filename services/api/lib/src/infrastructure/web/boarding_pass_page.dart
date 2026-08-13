import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/infrastructure/web/qr_svg.dart';
import 'package:bel_localization/bel_localization.dart';

/// The boarding pass, as a page (ADR-0026).
///
/// The reader bought at an agency counter, has no account, no app, and is
/// standing at a coach door at half past five in the morning. Everything about
/// this file follows from that.
///
/// **It is rendered whole, on the server, QR included.** The follower page
/// (ADR-0014) renders a shell and fetches its data, because it is watched for
/// ten minutes and updates while somebody reads it. A boarding pass is the
/// opposite: it is looked at once, at the worst moment, and a second round
/// trip there is a second chance to fail. So there is no `fetch`, no polling,
/// and **no JavaScript at all** — a browser with scripting off still boards.
///
/// **The QR is inline SVG**, for the same reason: an `<img>` pointing at an
/// endpoint is a request that can fail on its own after the page has painted,
/// which is the failure mode where somebody is holding up a blank white square
/// to a conductor.
///
/// **Black on white in both themes.** The page respects a dark theme
/// everywhere except the ticket card, because a dark QR is a QR the cheap
/// scanner at the door refuses.
///
/// **A voided seat is shown and struck through, never dropped.** A family of
/// three whose middle ticket was refunded must not find a page with two seats
/// on it and no explanation.
///
/// **It says the link needs a connection**, once, at the top — because the
/// honest fix for no signal is the message in their inbox, which carries the
/// same QR, and telling them that while they still have signal is the only
/// moment it helps.
abstract final class BoardingPassPage {
  static String render({
    required LinkedTicket ticket,
    required TranslationCatalog catalog,
    String language = 'fr',
  }) {
    final t = CatalogTranslator(catalog, language);
    final seats = StringBuffer();

    for (final seat in ticket.seats) {
      seats.write('''
  <section class="ticket${seat.voided ? ' dead' : ''}">
    <div class="qr-wrap">${QrSvg.render(seat.payload, label: t('boardingPass.seat', {'seat': seat.seatLabel}))}</div>
    <p class="seat">${_text(t('boardingPass.seat', {'seat': seat.seatLabel}))}</p>
    <p class="who">${_text(seat.passengerName)}</p>
    ${seat.voided ? '<p class="dead-note">${_text(t('boardingPass.voided'))}</p>' : ''}
  </section>
''');
    }

    final station = ticket.stationName;
    final notes = ticket.stationNotes;

    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(t('boardingPass.title'))}</title>
<meta name="robots" content="noindex,nofollow">
<style>
:root{--ink:#141a17;--soft:#6b7a72;--line:#e2e8e4;--brand:#0f6b4f;--warn:#b26a00;--bg:#fbfcfb}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
     font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:34rem;margin:0 auto;padding:1.5rem 1.25rem 3rem}
h1{font-size:1.5rem;margin:0 0 .25rem}
.sub{color:var(--soft);margin:0 0 1rem}
.card{background:#fff;border:1px solid var(--line);border-radius:12px;
      padding:1rem 1.1rem;margin-bottom:1rem}
.rows{display:flex;flex-wrap:wrap;gap:1rem}
.rows div{flex:1 1 8rem}
.k{color:var(--soft);font-size:.8rem;display:block}
.v{font-weight:600}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.note{color:var(--soft);font-size:.85rem;margin:.5rem 0 0}
/* White in both themes, always: a dark QR is one a cheap scanner refuses. */
.ticket{background:#fff;color:#141a17;border:1px solid var(--line);
        border-radius:12px;padding:1.1rem;margin-bottom:1rem;text-align:center}
.qr-wrap{max-width:15rem;margin:0 auto}
.qr{display:block;width:100%;height:auto}
.seat{font-size:1.35rem;font-weight:700;margin:.75rem 0 0}
.who{margin:.15rem 0 0;color:#6b7a72}
.dead .qr-wrap{opacity:.25}
.dead .seat{text-decoration:line-through}
.dead-note{margin:.5rem 0 0;color:#b3261e;font-size:.9rem}
.warn{border-color:#f0d9ae;background:#fdf6e9}
.warn p{margin:0;font-size:.9rem;color:var(--warn)}
.foot{color:var(--soft);font-size:.78rem;margin-top:1.5rem}
a.cta{display:block;text-align:center;margin-top:1.25rem;padding:.85rem;
      background:var(--brand);color:#fff;text-decoration:none;border-radius:10px}
@media(prefers-color-scheme:dark){
  :root{--ink:#e8efea;--soft:#93a49b;--line:#26312c;--bg:#0d1210}
  .card{background:#131a17}
  .warn{background:#2a2008;border-color:#4a3a12}
}
@media print{body{background:#fff}a.cta,.foot{display:none}}
</style>
</head>
<body>
<main>
  <h1>${_text(t('boardingPass.headline', {'origin': ticket.originCity, 'destination': ticket.destinationCity}))}</h1>
  <p class="sub">${_text(t('boardingPass.operator', {'operator': ticket.operatorName}))}</p>

  ${ticket.status == 'cancelled' ? '<div class="card warn"><p>${_text(t('boardingPass.cancelled'))}</p></div>' : ''}

  <div class="card">
    <div class="rows">
      <div><span class="k">${_text(t('boardingPass.departure'))}</span>
           <span class="v">${_text(_time(ticket.departsAt))}</span></div>
      <div><span class="k">${_text(t('boardingPass.arrival'))}</span>
           <span class="v">${_text(_time(ticket.arrivesAt))}</span></div>
      <div><span class="k">${_text(t('boardingPass.reference'))}</span>
           <span class="v mono">BEL-${_text(ticket.bookingRef)}</span></div>
    </div>
    ${station == null ? '' : '''
    <p class="note"><b>${_text(t('boardingPass.station'))}:</b> ${_text(station)}</p>
    ${notes == null || notes.isEmpty ? '' : '<p class="note">${_text(notes)}</p>'}'''}
  </div>

$seats
  <p class="foot">${_text(t('boardingPass.instructions'))}</p>
  <p class="foot">${_text(t('boardingPass.offline'))}</p>
  <p class="foot">${_text(t('boardingPass.expires', {'date': _date(ticket.expiresAt)}))}</p>
  <a class="cta" href="/">${_text(t('boardingPass.cta'))}</a>
</main>
</body>
</html>
''';
  }

  /// The same page, for a link that no longer resolves.
  ///
  /// Revoked, expired and never-issued render one sentence, because the holder
  /// cannot act on the difference and the traveller did not ask to explain it.
  static String renderGone({
    required TranslationCatalog catalog,
    String language = 'fr',
  }) {
    final t = CatalogTranslator(catalog, language);
    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(t('boardingPass.gone'))}</title>
<meta name="robots" content="noindex,nofollow">
<style>
body{margin:0;background:#fbfcfb;color:#141a17;
     font:16px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:34rem;margin:0 auto;padding:3rem 1.25rem}
h1{font-size:1.35rem;margin:0 0 .5rem}
p{color:#6b7a72;margin:0}
a{display:block;text-align:center;margin-top:2rem;padding:.85rem;
  background:#0f6b4f;color:#fff;text-decoration:none;border-radius:10px}
@media(prefers-color-scheme:dark){body{background:#0d1210;color:#e8efea}
  p{color:#93a49b}}
</style>
</head>
<body>
<main>
  <h1>${_text(t('boardingPass.gone'))}</h1>
  <p>${_text(t('boardingPass.goneBody'))}</p>
  <a href="/">${_text(t('boardingPass.cta'))}</a>
</main>
</body>
</html>
''';
  }

  /// Brazzaville is UTC+1 and does not observe daylight saving, so the offset
  /// is a constant rather than a timezone database on a page somebody opens on
  /// 2G (the same constant the follower page carries).
  static String _time(DateTime utc) {
    final local = utc.toUtc().add(const Duration(hours: 1));
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _date(DateTime utc) {
    final local = utc.toUtc().add(const Duration(hours: 1));
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  static String _attr(String value) =>
      value.replaceAll('"', '').replaceAll('<', '');

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
