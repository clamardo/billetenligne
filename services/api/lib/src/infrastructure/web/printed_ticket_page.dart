import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';

import 'accent_hues.dart';
import 'qr_svg.dart';
import 'weave.dart';

/// The ticket on paper, for the sale that ends across a counter.
///
/// **This is the common path, not the fallback.** Most seats in this market
/// are bought with cash from an agency by somebody who will not install an
/// app. That sale has to end with something in their hand, and the something
/// has to scan at the door exactly like a phone does.
///
/// It does. `LinkedSeat.payload` is the complete signed string and it is
/// **static** — the control at the door is one scan per seat, not freshness
/// (ADR-0007, ADR-0026). The rotating six digits on the traveller's screen
/// defend against a screenshot of a *live* QR; a printed ticket carries no
/// freshness code at all and verifies as `valid`. The console's counter
/// receipt used to say the opposite in a doc comment, and that sentence was
/// the only thing standing between this market and its most likely ticket.
///
/// **Everything on this page is one request.** No stylesheet, no font, no
/// image fetch, no script the ticket depends on. A print dialog that opens
/// before a webfont arrives lays out the wrong widths; an `<img>` that 404s
/// leaves a white hole where the company's mark should be, on paper, where
/// nobody can reload it. So the mark is a drawn monogram and the weave is a
/// `data:` URI.
///
/// **Colour prints here, unlike the boarding-pass page.** That page strips
/// the operator's hue on print because it is the *traveller's* copy and a
/// station's printer is not owed a cartridge. This one is the operator's own
/// stationery — they asked for their header and their ground — so it prints
/// as designed, and the operator who would rather spend no ink chooses the
/// economy starter, which has none to spend.
abstract final class PrintedTicketPage {
  static String render({
    required LinkedTicket ticket,
    required TicketDesign design,
    required TranslationCatalog catalog,
    String language = 'fr',
    bool autoPrint = false,
  }) {
    final t = CatalogTranslator(catalog, language);
    final accent = AccentHues.hex(ticket.operatorAccentHue);
    final sheet = design.format.sheet;
    // Drawn in white, not in the accent. The header *is* the accent, and a
    // weave in the same hue as the ground it sits on is a weave nobody can
    // see — which is how the first draft of this page shipped a motif that
    // rendered perfectly and looked like a plain green bar.
    //
    // Quiet, at 0.22. The band carries the company's name and the word
    // "ticket"; at full strength the cloth reads first and the name second,
    // which is the wrong way round on the one object a conductor identifies
    // a company by. Not pre-encoded either — `Weave` escapes the `#`, and
    // passing `%23ffffff` produces `%2523ffffff`, a colour that draws the
    // pattern's dots and none of its strokes.
    final weave = design.motif == 'flat'
        ? 'none'
        : Weave.image('#ffffff', opacity: 0.22, strokeWidth: 2.6);
    final page = design.format == TicketFormat.a4;

    final passes = StringBuffer();
    for (final seat in ticket.seats) {
      passes.write(_pass(ticket, seat, design, t, accent, language));
    }

    final live = ticket.seats.where((s) => !s.voided).length;

    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(t('printedTicket.title', {'ref': ticket.bookingRef}))}</title>
<meta name="robots" content="noindex,nofollow">
<style>
:root{--ink:#141a17;--soft:#6b7a72;--line:#cfd8d3;--brand:$accent}
*{box-sizing:border-box}
body{margin:0;background:#e8ece9;color:var(--ink);
     font:11pt/1.35 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
.bar{position:sticky;top:0;background:#fff;border-bottom:1px solid var(--line);
     padding:.75rem 1rem;display:flex;gap:.75rem;align-items:center;
     flex-wrap:wrap}
.bar p{margin:0;color:var(--soft);font-size:.85rem;flex:1 1 14rem}
.bar button,.bar a{font:inherit;padding:.55rem 1.1rem;border-radius:8px;
     border:1px solid var(--brand);background:var(--brand);color:#fff;
     text-decoration:none;cursor:pointer}
.bar a.ghost{background:#fff;color:var(--brand)}
.sheet{margin:1rem auto;padding:10mm;background:#fff;width:210mm;
       box-shadow:0 1px 4px rgba(0,0,0,.18)}

/* The pass itself. Widths are in millimetres because the output is paper:
   a pass laid out in `rem` is a pass whose size depends on a browser's
   default font, and one that comes out 4 mm wider than the cut is a pass
   with its own QR trimmed off. */
.pass{width:${sheet.width};height:${sheet.height};border:1px solid var(--line);
      border-radius:3mm;overflow:hidden;display:flex;
      flex-direction:${page ? 'column' : 'row'};
      page-break-inside:avoid;break-inside:avoid;background:#fff}
.pass+.pass{margin-top:4mm}
/* On a pass the stub takes the width and the code takes its column. On a
   page the stub takes only what it needs and the code centres in the rest,
   because a full sheet laid out the other way is a paragraph at the top and
   two thirds of nothing. */
.stub{flex:${page ? '0 0 auto' : '1 1 auto'};display:flex;flex-direction:column;
      min-width:0;min-height:0}
.head{background:var(--brand);color:#fff;padding:3mm 4mm;
      background-image:$weave;background-size:24mm 24mm;
      background-position:center}
.head .row{display:flex;align-items:center;gap:3mm}
.mark{width:11mm;height:11mm;border-radius:2.5mm;background:rgba(255,255,255,.22);
      display:flex;align-items:center;justify-content:center;
      font-weight:700;letter-spacing:.5px;flex:0 0 auto}
.co{font-weight:700;font-size:1.05em;margin:0;overflow:hidden;
    text-overflow:ellipsis;white-space:nowrap}
.kind{margin:0;font-size:.72em;opacity:.9;text-transform:uppercase;
      letter-spacing:1px}
.body{padding:3mm 4mm;flex:1;display:flex;flex-direction:column;gap:2mm}
.route{font-size:1.5em;font-weight:700;margin:0;line-height:1.1}
.when{margin:0;color:var(--soft)}
.grid{display:flex;flex-wrap:wrap;gap:3mm 6mm;
      margin-top:${page ? '2mm' : 'auto'}}
.grid div{min-width:22mm}
.k{display:block;color:var(--soft);font-size:.68em;text-transform:uppercase;
   letter-spacing:.6px}
.v{font-weight:700;font-size:1.05em}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
.note{margin:0;color:var(--soft);font-size:.72em}

/* The perforation, and the QR panel it separates. The panel is white and
   fixed-width whatever the design says: a code the scanner cannot find is
   not a design choice. */
.tear{flex:0 0 0;border-${page ? 'top' : 'left'}:1px dashed var(--line)}
.code{flex:${page ? '1 1 auto' : '0 0 52mm'};
      background:#fff;color:#141a17;padding:3mm;text-align:center;
      display:flex;flex-direction:column;justify-content:center;
      align-items:center;gap:1mm}
/* Capped, not stretched. On a full page an uncapped QR grows to the width of
   the sheet, and a code the size of a dinner plate is no easier to scan than
   one the size of a hand — it is only harder to hold still. */
.code svg{display:block;width:100%;max-width:${page ? '86mm' : '46mm'};
          height:auto}
.seat{font-size:1.35em;font-weight:700;margin:0}
.who{margin:0;color:var(--soft);font-size:.8em;overflow:hidden;
     text-overflow:ellipsis;white-space:nowrap}
.dead .code svg{opacity:.2}
.dead .seat{text-decoration:line-through}
.dead-note{margin:0;color:#b3261e;font-size:.72em}
.foot{padding:0 4mm 3mm;color:var(--soft);font-size:.7em}

@media print{
  /* The operator's own stationery, so their colours survive the driver's
     default of stripping backgrounds. */
  html,body{background:#fff;-webkit-print-color-adjust:exact;
            print-color-adjust:exact}
  .bar{display:none}
  .sheet{width:auto;margin:0;padding:0;box-shadow:none}
  @page{size:${sheet.page};margin:10mm}
}
</style>
</head>
<body>
<div class="bar">
  <p>${_text(t('printedTicket.lead', {'count': live, 'format': t(design.format.labelKey)}))}</p>
  <button type="button" onclick="window.print()">${_text(t('printedTicket.print'))}</button>
  <a class="ghost" href="?format=${design.format == TicketFormat.a4 ? TicketFormat.boardingPass.name : TicketFormat.a4.name}&lang=${_attr(language)}">${_text(t(design.format == TicketFormat.a4 ? 'printedTicket.switchToPass' : 'printedTicket.switchToA4'))}</a>
</div>
<div class="sheet">
$passes</div>
${autoPrint ? '<script>window.addEventListener("load",function(){window.print()})</script>' : ''}
</body>
</html>
''';
  }

  static String _pass(
    LinkedTicket ticket,
    LinkedSeat seat,
    TicketDesign design,
    CatalogTranslator t,
    String accent,
    String language,
  ) {
    final footer = language == 'en' ? design.footerEn : design.footerFr;
    final station = ticket.stationName;

    return '''
<article class="pass${seat.voided ? ' dead' : ''}">
  <div class="stub">
    <header class="head">
      <div class="row">
        ${design.showLogo ? '<div class="mark">${_text(_initials(ticket.operatorName))}</div>' : ''}
        <div style="min-width:0">
          <p class="co">${_text(ticket.operatorName)}</p>
          <p class="kind">${_text(t('printedTicket.kind'))}</p>
        </div>
      </div>
    </header>
    <div class="body">
      <p class="route">${_text(ticket.originCity)} → ${_text(ticket.destinationCity)}</p>
      <p class="when">${_text(_date(ticket.departsAt))} · ${_text(_time(ticket.departsAt))}${design.shows(TicketField.arrival) ? ' → ${_text(_time(ticket.arrivesAt))}' : ''}</p>
      ${design.shows(TicketField.station) && station != null ? '<p class="note"><b>${_text(t('printedTicket.station'))}:</b> ${_text(station)}</p>' : ''}
      ${design.shows(TicketField.boardingNote) ? '<p class="note">${_text(t('printedTicket.beEarly'))}</p>' : ''}
      <div class="grid">
        <div><span class="k">${_text(t('printedTicket.passenger'))}</span>
             <span class="v">${_text(seat.passengerName)}</span></div>
        <div><span class="k">${_text(t('printedTicket.seat'))}</span>
             <span class="v">${_text(seat.seatLabel)}</span></div>
        <div><span class="k">${_text(t('printedTicket.reference'))}</span>
             <span class="v mono">BEL-${_text(ticket.bookingRef)}</span></div>
      </div>
    </div>
    ${footer == null || footer.isEmpty ? '' : '<p class="foot">${_text(footer)}</p>'}
  </div>
  <div class="tear"></div>
  <div class="code">
    ${QrSvg.render(seat.payload, label: t('printedTicket.seat'))}
    <p class="seat">${_text(seat.seatLabel)}</p>
    <p class="who">${_text(seat.passengerName)}</p>
    ${seat.voided ? '<p class="dead-note">${_text(t('printedTicket.voided'))}</p>' : ''}
  </div>
</article>
''';
  }

  /// The same monogram the storefront falls back to, so an operator with no
  /// uploaded logo is the same mark in both places.
  static String _initials(String name) {
    final words = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList(growable: false);
    if (words.isEmpty) return 'BEL';
    if (words.length == 1) {
      return words.first.substring(0, 1).toUpperCase();
    }
    return (words[0].substring(0, 1) + words[1].substring(0, 1)).toUpperCase();
  }

  /// Brazzaville is UTC+1 with no daylight saving, so the offset is a
  /// constant rather than a timezone database on a page that has to print.
  static String _time(DateTime utc) {
    final local = utc.add(const Duration(hours: 1));
    return '${local.hour.toString().padLeft(2, '0')}h'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _date(DateTime utc) {
    final local = utc.add(const Duration(hours: 1));
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  static String _text(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _attr(String v) => _text(v).replaceAll('"', '&quot;');
}
