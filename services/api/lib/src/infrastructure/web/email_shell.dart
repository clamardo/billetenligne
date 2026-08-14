import 'package:bel_localization/bel_localization.dart';

/// The house chrome every outgoing e-mail is drawn in.
///
/// **Why this exists.** Every message this product sends was plain text except
/// the ticket, and the ticket carried its own hardcoded palette that had
/// already drifted from the brand — `#0f6b4f` where the token says `#0A6B4F`.
/// So the first thing anybody ever receives from BilletEnLigne, the sign-in
/// code, arrived looking like a machine wrote it, and the one styled message
/// was styled slightly wrong. One shell, one palette, one place to change it.
///
/// **Tables and inline styles**, which is not how anything else in this
/// repository is written and is how e-mail has to be written: no stylesheet
/// survives Gmail, and a flex layout collapses in Outlook. Widths are in
/// pixels for the same reason — `rem` is unreliable in Outlook's Word
/// renderer, which is a large share of the operator side.
///
/// **No images at all, deliberately.** The wordmark is set in type rather than
/// drawn: Gmail strips `data:` images, a hosted one needs a domain nobody has
/// registered yet, and a remote logo is a tracking pixel by another name. A
/// header that renders on a 2G handset with images off is worth more than a
/// mark.
///
/// **Prose never appears here.** Every word comes in already translated
/// (ADR-0008 / ADR-0019 rule 3); this file contributes punctuation and colour.
abstract final class EmailShell {
  // ── The palette, from `KiloColors.light` ────────────────────────────────
  //
  // Named rather than inlined so the drift that produced `#0f6b4f` cannot
  // happen twice. Light only: `prefers-color-scheme` works in Apple Mail and
  // is ignored by Gmail, so a dark variant would be a coin toss about which
  // half of the audience sees a broken message.
  static const _brand = '#0A6B4F';
  static const _ink = '#141A17';
  static const _muted = '#5F6E67';
  static const _ground = '#F4F7F5';
  static const _card = '#FFFFFF';
  static const _line = '#DEE7E2';
  static const _soft = '#E4F1EB';

  /// [heading] is the sentence at the top. [paragraphs] is the plain-text body
  /// split on blank lines — the same words, in the same order, so a client
  /// showing the text part and one showing this part say the same thing.
  ///
  /// [highlight] is set only where a few characters are the whole point.
  static String render({
    required TranslationCatalog catalog,
    required String language,
    required String heading,
    required List<String> paragraphs,
    String? highlight,
    String? footnote,
    String? action,
    String? actionUrl,
    String? card,
  }) {
    final t = CatalogTranslator(catalog, language);
    final body = StringBuffer();

    // The inbox preview line. Without one, Gmail pulls the first thing it
    // finds — which for a code is the code, sitting in a notification on a
    // lock screen where anybody can read it.
    body.write(
      '<div style="display:none;max-height:0;overflow:hidden;opacity:0">'
      '${_text(t('email.shell.preview'))}</div>',
    );

    body.write(
      '<tr><td style="padding:28px 24px 20px">'
      '<span style="font-size:15px;font-weight:700;letter-spacing:.14em;'
      'text-transform:uppercase;color:$_brand">BilletEnLigne</span>'
      '</td></tr>',
    );

    body.write(
      '<tr><td style="padding:0 24px">'
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
      'style="background:$_card;border:1px solid $_line;border-radius:14px">'
      '<tr><td style="padding:26px 24px">',
    );

    body.write(
      '<h1 style="margin:0 0 14px;font-size:21px;line-height:1.25;'
      'font-weight:600;color:$_ink">${_text(heading)}</h1>',
    );

    if (highlight != null && highlight.isNotEmpty) {
      // Letter-spaced and large because it is copied by hand, often from a
      // cracked screen in daylight. `monospace` so 0 and O are not a guess.
      body.write(
        '<table role="presentation" width="100%" cellpadding="0" '
        'cellspacing="0" style="background:$_soft;border-radius:10px;'
        'margin:0 0 18px"><tr><td align="center" '
        'style="padding:18px 12px;font-family:ui-monospace,Menlo,Consolas,'
        'monospace;font-size:32px;line-height:1.1;font-weight:700;'
        'letter-spacing:.22em;color:$_brand">${_text(highlight)}</td>'
        '</tr></table>',
      );
    }

    if (card != null && card.isNotEmpty) body.write(card);

    for (final p in paragraphs) {
      if (p.trim().isEmpty) continue;
      body.write(
        '<p style="margin:0 0 12px;font-size:15px;line-height:1.6;'
        'color:$_ink">${_paragraph(p)}</p>',
      );
    }

    if (action != null && actionUrl != null && actionUrl.isNotEmpty) {
      body.write(
        '<p style="margin:20px 0 0"><a href="${_attr(actionUrl)}" '
        'style="display:block;text-align:center;padding:14px;'
        'background:$_brand;color:#ffffff;text-decoration:none;'
        'border-radius:10px;font-weight:600;font-size:15px">'
        '${_text(action)}</a></p>'
        '<p style="margin:12px 0 0;font-size:12px;color:$_muted;'
        'word-break:break-all">${_attr(actionUrl)}</p>',
      );
    }

    if (footnote != null && footnote.isNotEmpty) {
      body.write(
        '<p style="margin:16px 0 0;font-size:13px;line-height:1.55;'
        'color:$_muted">${_paragraph(footnote)}</p>',
      );
    }

    body.write('</td></tr></table></td></tr>');

    body.write(
      '<tr><td style="padding:18px 24px 32px;font-size:12px;line-height:1.6;'
      'color:$_muted">${_lines(t('email.shell.footer'))}</td></tr>',
    );

    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(heading)}</title></head>
<body style="margin:0;padding:0;background:$_ground;color:$_ink;
             font-family:system-ui,-apple-system,'Segoe UI',Roboto,Helvetica,
             Arial,sans-serif;-webkit-font-smoothing:antialiased">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"
       style="background:$_ground"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"
       style="max-width:544px;margin:0 auto;text-align:left">
$body
</table>
</td></tr></table>
</body>
</html>
''';
  }

  /// A detail table — the facts somebody checks before they trust the message.
  static String facts(List<(String, String)> rows) {
    if (rows.isEmpty) return '';
    final out = StringBuffer(
      '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
      'style="margin:0 0 18px;border-top:1px solid $_line">',
    );
    for (final (label, value) in rows) {
      out.write(
        '<tr><td style="padding:9px 12px 9px 0;font-size:14px;color:$_muted;'
        'border-bottom:1px solid $_line">${_text(label)}</td>'
        '<td style="padding:9px 0;font-size:14px;font-weight:600;color:$_ink;'
        'text-align:right;border-bottom:1px solid $_line">'
        '${_text(value)}</td></tr>',
      );
    }
    return (out..write('</table>')).toString();
  }

  /// The plain-text body, as the paragraphs it was written as.
  ///
  /// Blank-line separated, which is how every `body:` in the catalog is
  /// already shaped — so the HTML gains its structure from the prose rather
  /// than from a second copy of it that could drift.
  static List<String> paragraphsOf(String body) => body
      .replaceAll('\r\n', '\n')
      .split(RegExp(r'\n\s*\n'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList(growable: false);

  /// Escaped, with the catalog's own wrapping undone.
  ///
  /// Every `body:` in the catalog is hard-wrapped at about seventy columns,
  /// because its first job is to be read as plain text in a terminal or a mail
  /// client with no styling. Carrying those newlines into HTML reflows a
  /// paragraph twice — once by the author and once by the browser — and the
  /// result is the ragged short line this used to produce halfway through
  /// every sentence. So a single newline is a space, and only a blank line
  /// starts a new paragraph, which is what [paragraphsOf] already splits on.
  static String _paragraph(String value) =>
      _text(value).replaceAll(RegExp(r'\s*\n\s*'), ' ');

  /// The same, for the few places where the lines are the point.
  ///
  /// The footer is two separate statements rather than one wrapped sentence,
  /// and a set of directions to a yard is written a line at a time on purpose.
  static String _lines(String value) =>
      _text(value.trimRight()).replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '<br>');

  static String _attr(String value) =>
      value.replaceAll('"', '').replaceAll('<', '').replaceAll('>', '');

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
