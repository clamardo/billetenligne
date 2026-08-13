import 'package:bel_localization/bel_localization.dart';

/// One seat, as it appears in the message.
final class EmailedSeat {
  const EmailedSeat({required this.seatLabel, required this.passengerName});

  final String seatLabel;
  final String passengerName;
}

/// The ticket, in an inbox (ADR-0026).
///
/// The page is the thing they open; this is the thing they still have when
/// they cannot open anything. So it carries **everything needed to board** —
/// the road, the company, the day and hour, the yard and the directions to it,
/// the reference, every seat and its passenger — and the QR travels beside it
/// as a file rather than as a link to one.
///
/// **HTML in addition to the plain text, never instead of it.** The plain text
/// is composed from the same catalog and says the same facts; a client that
/// renders neither HTML nor images still shows somebody a message they can act
/// on. That is not a nicety in this market — it is most of the handsets.
///
/// **Tables and inline styles**, which is not how anything else in this
/// repository is written and is how email has to be written: no stylesheet
/// survives Gmail, and a flexbox layout collapses in Outlook.
abstract final class TicketEmail {
  static String render({
    required String originCity,
    required String destinationCity,
    required String operatorName,
    required String date,
    required String time,
    required String reference,
    required List<EmailedSeat> seats,
    required String url,
    required TranslationCatalog catalog,
    String? stationName,
    String? stationNotes,
    String language = 'fr',
  }) {
    final t = CatalogTranslator(catalog, language);
    final rows = StringBuffer();

    for (final seat in seats) {
      rows.write(
        '<tr>'
        '<td style="padding:6px 12px 6px 0;font-weight:700">'
        '${_text(t('boardingPass.seat', {'seat': seat.seatLabel}))}</td>'
        '<td style="padding:6px 0;color:#6b7a72">'
        '${_text(seat.passengerName)}</td>'
        '</tr>',
      );
    }

    String line(String key, String value) =>
        '<tr><td style="padding:4px 12px 4px 0;color:#6b7a72">'
        '${_text(t(key))}</td>'
        '<td style="padding:4px 0;font-weight:600">${_text(value)}</td></tr>';

    return '''
<!doctype html>
<html lang="${_attr(language)}">
<head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${_text(t('boardingPass.title'))}</title></head>
<body style="margin:0;background:#fbfcfb;color:#141a17;
             font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"
       style="max-width:34rem;margin:0 auto"><tr><td style="padding:24px 20px">
  <h1 style="font-size:20px;margin:0 0 4px">${_text(t('boardingPass.headline', {'origin': originCity, 'destination': destinationCity}))}</h1>
  <p style="margin:0 0 20px;color:#6b7a72">${_text(t('boardingPass.operator', {'operator': operatorName}))}</p>

  <table role="presentation" cellpadding="0" cellspacing="0"
         style="width:100%;background:#fff;border:1px solid #e2e8e4;
                border-radius:12px;padding:12px 16px">
    ${line('boardingPass.departure', '$date $time')}
    ${line('boardingPass.reference', reference)}
    ${stationName == null ? '' : line('boardingPass.station', stationName)}
  </table>
  ${stationNotes == null || stationNotes.isEmpty ? '' : '<p style="margin:8px 0 0;color:#6b7a72;font-size:14px">${_text(stationNotes)}</p>'}

  <table role="presentation" cellpadding="0" cellspacing="0"
         style="width:100%;margin-top:16px">$rows</table>

  <!-- Said before the attachment rather than after it: somebody scrolling a
       phone screen sees the sentence and then the codes, in that order. -->
  <p style="margin:20px 0 0;font-size:14px">${_text(t('email.ticketLink.attached'))}</p>
  <p style="margin:8px 0 0;font-size:14px;color:#6b7a72">${_text(t('boardingPass.instructions'))}</p>

  <p style="margin:24px 0 0"><a href="${_attr(url)}"
     style="display:block;text-align:center;padding:14px;background:#0f6b4f;
            color:#fff;text-decoration:none;border-radius:10px">${_text(t('email.ticketLink.open'))}</a></p>
  <p style="margin:16px 0 0;font-size:12px;color:#6b7a72;word-break:break-all">${_attr(url)}</p>
</td></tr></table>
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
