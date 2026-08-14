import 'package:bel_localization/bel_localization.dart';

import 'email_shell.dart';

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
/// **Drawn in the shared shell** (`email_shell.dart`) rather than in a layout
/// of its own. It used to carry its own palette, and that palette had already
/// drifted — `#0f6b4f` where the design token says `#0A6B4F`, which is the
/// exact failure a second copy of a colour always produces. What stays here is
/// the part that is genuinely a boarding pass rather than a letter: the seats,
/// the yard and the directions to it.
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
        '<td style="padding:6px 0;color:#5F6E67">'
        '${_text(seat.passengerName)}</td>'
        '</tr>',
      );
    }

    final notes = stationNotes == null || stationNotes.isEmpty
        ? ''
        : '<p style="margin:-8px 0 16px;color:#5F6E67;font-size:14px">'
              '${_text(stationNotes)}</p>';

    return EmailShell.render(
      catalog: catalog,
      language: language,
      heading: t('boardingPass.headline', {
        'origin': originCity,
        'destination': destinationCity,
      }),
      // The boarding pass itself: who is carrying you, when, from which yard,
      // and which seat is yours. Above the prose, because this is the part
      // somebody opens the message to look at.
      card:
          '<p style="margin:0 0 16px;font-size:15px;color:#5F6E67">'
          '${_text(t('boardingPass.operator', {'operator': operatorName}))}</p>'
          '${EmailShell.facts([(t('boardingPass.departure'), '$date $time'), (t('boardingPass.reference'), reference), if (stationName != null) (t('boardingPass.station'), stationName)])}'
          '$notes'
          '<table role="presentation" cellpadding="0" cellspacing="0" '
          'style="width:100%;margin:0 0 18px">$rows</table>',
      // Said before the attachment rather than after it: somebody scrolling a
      // phone screen sees the sentence and then the codes, in that order.
      paragraphs: [
        t('email.ticketLink.attached'),
        t('boardingPass.instructions'),
      ],
      action: t('email.ticketLink.open'),
      actionUrl: url,
    );
  }

  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
