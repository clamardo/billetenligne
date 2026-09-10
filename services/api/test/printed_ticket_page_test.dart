import 'dart:io';

import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/infrastructure/web/printed_ticket_page.dart';
import 'package:bel_api/src/infrastructure/web/qr_svg.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:qr/qr.dart';
import 'package:test/test.dart';

/// The catalog the server actually ships. Half of what a printed ticket has
/// to get right is whether the sentence exists at all, and a missing key
/// renders as a key — on paper, where nobody can reload it.
final _catalog = CatalogLoader.fromDirectory(_i18nDirectory());

String _i18nDirectory() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_localization/i18n';
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('i18n directory not found from ${Directory.current.path}');
}

LinkedTicket _ticket({List<LinkedSeat>? seats, String? accentHue = 'indigo'}) =>
    LinkedTicket(
      bookingRef: 'PRN001',
      state: 'confirmed',
      operatorName: 'Océan du Nord',
      operatorCode: 'ODN',
      operatorAccentHue: accentHue,
      routeCode: 'BZV-PNR',
      originCity: 'Brazzaville',
      destinationCity: 'Pointe-Noire',
      departsAt: DateTime.utc(2026, 8, 20, 5),
      arrivesAt: DateTime.utc(2026, 8, 20, 13),
      status: 'scheduled',
      stationName: 'Gare de Mikalou',
      stationNotes: 'Portail vert',
      channel: 'email',
      expiresAt: DateTime.utc(2026, 8, 21, 13),
      seats:
          seats ??
          const [
            LinkedSeat(
              seatLabel: '12A',
              passengerName: 'Aline Massamba',
              payload: 'BEL1.eyJyIjoiUFJOMDAxIn0.c2ln',
            ),
          ],
    );

void main() {
  group('the ticket on paper', () {
    test('carries a QR per seat, drawn into the page', () {
      final html = PrintedTicketPage.render(
        ticket: _ticket(
          seats: const [
            LinkedSeat(
              seatLabel: '12A',
              passengerName: 'Aline Massamba',
              payload: 'BEL1.aaa.sig',
            ),
            LinkedSeat(
              seatLabel: '12B',
              passengerName: 'Josué Massamba',
              payload: 'BEL1.bbb.sig',
            ),
          ],
        ),
        design: TicketStarters.classicPass,
        catalog: _catalog,
      );

      // Two passes, two codes. Not one page with a code on it — a family of
      // three boards through three scans.
      expect('<article'.allMatches(html).length, 2);
      expect('<svg'.allMatches(html).length, greaterThanOrEqualTo(2));
      expect(html, contains('12A'));
      expect(html, contains('Josué Massamba'));
    });

    test('nothing on it is fetched', () {
      final html = PrintedTicketPage.render(
        ticket: _ticket(),
        design: TicketStarters.classicPass,
        catalog: _catalog,
      );

      // A print dialog that opens before a webfont arrives lays out the wrong
      // widths; an <img> that 404s leaves a hole on paper. So: no external
      // stylesheet, no font, no image, and the only <script> is the one that
      // auto-prints — which this render did not ask for.
      expect(html, isNot(contains('<link')));
      expect(html, isNot(contains('<img')));
      expect(html, isNot(contains('<script')));
      expect(html, isNot(contains('src=')));
      expect(html, isNot(contains('@import')));
      // `http://www.w3.org/2000/svg` is an XML namespace, not an address
      // anything dials — so the assertion is about `url()`, which is.
      expect(html, isNot(contains('url(http')));
      expect(html, isNot(contains("url('http")));
    });

    test('the sheet is sized in millimetres, and told to print in colour', () {
      final html = PrintedTicketPage.render(
        ticket: _ticket(),
        design: TicketStarters.classicPass,
        catalog: _catalog,
      );

      expect(html, contains('@page{size:A4 portrait;margin:10mm}'));
      expect(html, contains('height:88mm'));
      // Three to a sheet is the whole point of the default: an agency has an
      // A4 inkjet and ordinary paper, not a boarding-pass printer.
      expect(TicketFormat.boardingPass.perSheet, 3);
      // The operator's own stationery, so the driver must not strip it.
      expect(html, contains('print-color-adjust:exact'));
      // And a pass may never be split across two sheets.
      expect(html, contains('page-break-inside:avoid'));
    });

    test('the A4 starter puts one to a page and a bigger code on it', () {
      final html = PrintedTicketPage.render(
        ticket: _ticket(),
        design: TicketStarters.fullPageReceipt,
        catalog: _catalog,
      );

      expect(html, contains('height:277mm'));
      expect(html, contains('flex:1 1 auto'));
      // Stacked, not side by side: a full page laid out in two columns is
      // two columns of white either side of a hand-sized code.
      expect(html, contains('flex-direction:column'));
      expect(html, contains('max-width:86mm'));
      expect(TicketFormat.a4.perSheet, 1);
    });

    test('every sentence on it comes from the catalog', () {
      for (final language in const ['fr', 'en']) {
        final html = PrintedTicketPage.render(
          ticket: _ticket(),
          design: TicketStarters.classicPass,
          catalog: _catalog,
          language: language,
        );
        // A key rendered instead of a sentence is what a missing catalog
        // entry looks like, and on paper it is permanent.
        expect(
          html,
          isNot(contains('printedTicket.')),
          reason: '$language is missing a printedTicket key',
        );
        expect(
          html,
          isNot(contains('enum.TicketFormat.')),
          reason: '$language is missing a TicketFormat label',
        );
      }
    });

    test('a cancelled seat is struck through, never dropped', () {
      final html = PrintedTicketPage.render(
        ticket: _ticket(
          seats: const [
            LinkedSeat(
              seatLabel: '12A',
              passengerName: 'Aline Massamba',
              payload: 'BEL1.aaa.sig',
            ),
            LinkedSeat(
              seatLabel: '12B',
              passengerName: 'Josué Massamba',
              payload: 'BEL1.bbb.sig',
              voided: true,
            ),
          ],
        ),
        design: TicketStarters.classicPass,
        catalog: _catalog,
      );

      // A family of three handed two tickets counts their children at a
      // coach door wondering what happened.
      expect('<article'.allMatches(html).length, 2);
      expect(html, contains('pass dead'));
    });

    test('an economy design spends no ink it was not asked for', () {
      final html = PrintedTicketPage.render(
        ticket: _ticket(),
        design: TicketStarters.economyPass,
        catalog: _catalog,
      );

      expect(html, contains('background-image:none'));
      expect(html, isNot(contains('class="mark"')));
    });

    test('the square on the paper is the square the scanner accepts', () {
      const payload =
          '1|BEL|K195CM|10A|dep-1|1789016400|BZV-PNR|DEMO-ALZ|Juste Bouiti|1.sig';

      final html = PrintedTicketPage.render(
        ticket: _ticket(
          seats: const [
            LinkedSeat(
              seatLabel: '10A',
              passengerName: 'Juste Bouiti',
              payload: payload,
            ),
          ],
        ),
        design: TicketStarters.classicPass,
        catalog: _catalog,
      );

      final drawn = _modulesFromSvg(html);
      final encoded = QrImage(
        QrCode.fromData(
          data: payload,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      );

      const quiet = QrSvg.quietZone;
      final expected = <(int, int)>{
        for (var row = 0; row < encoded.moduleCount; row++)
          for (var col = 0; col < encoded.moduleCount; col++)
            if (encoded.isDark(row, col)) (col + quiet, row + quiet),
      };

      expect(drawn, isNotEmpty);
      expect(drawn, expected);
    });

    test('an unreadable stored design still prints a ticket', () {
      // A counter that cannot sell because a JSON blob gained a field is a
      // counter that turns customers away.
      final design = TicketDesign.fromJson(const {
        'format': 'somethingLater',
        'fields': ['station', 'aFieldThisBuildHasNeverHeardOf'],
      });

      expect(design.format, TicketFormat.boardingPass);
      expect(design.fields, {TicketField.station});
      expect(
        PrintedTicketPage.render(
          ticket: _ticket(),
          design: design,
          catalog: _catalog,
        ),
        contains('<article'),
      );
    });
  });
}

/// Rebuilds the module grid from the `<path>` the page drew.
///
/// The whole feature rests on one claim: **the square printed on the paper is
/// the same square the scanner accepts.** Asserting that the payload appears
/// in the HTML would not prove it — the payload is not in the HTML, only a
/// drawing of it is — so this reads the rectangles back out of the path and
/// compares them, module for module, with what the encoder produces for the
/// same string. A future optimisation of `QrSvg` that shifts a run by one
/// module would fail here rather than at a coach door.
Set<(int, int)> _modulesFromSvg(String svg) {
  final path = RegExp(r'<path fill="#000" d="([^"]*)"').firstMatch(svg)!;
  final rects = RegExp(r'M(\d+) (\d+)h(\d+)v1h-\3z');
  return {
    for (final m in rects.allMatches(path.group(1)!))
      for (var i = 0; i < int.parse(m.group(3)!); i++)
        (int.parse(m.group(1)!) + i, int.parse(m.group(2)!)),
  };
}
