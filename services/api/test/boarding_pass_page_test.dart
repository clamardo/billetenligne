import 'dart:io';

import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/infrastructure/web/boarding_pass_page.dart';
import 'package:bel_api/src/infrastructure/web/qr_svg.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:qr/qr.dart';
import 'package:test/test.dart';

/// The catalog the server actually ships, for the same reason the statement
/// document loads it: half of what this page has to get right is whether the
/// sentence exists at all, and a missing key renders as a key on a page
/// somebody holds up to a conductor.
final _catalog = CatalogLoader.fromDirectory(_i18nDirectory());

String _i18nDirectory() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_localization/i18n';
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('i18n directory not found from ${Directory.current.path}');
}

LinkedTicket _ticket({
  List<LinkedSeat>? seats,
  String status = 'scheduled',
  String? stationName = 'Gare de Mikalou',
  String? stationNotes = 'Portail vert, à côté du marché',
}) => LinkedTicket(
  bookingRef: 'LNK001',
  state: 'confirmed',
  operatorName: 'Océan du Nord',
  operatorCode: 'ODN',
  routeCode: 'BZV-PNR',
  originCity: 'Brazzaville',
  destinationCity: 'Pointe-Noire',
  departsAt: DateTime.utc(2026, 8, 20, 5),
  arrivesAt: DateTime.utc(2026, 8, 20, 13),
  status: status,
  stationName: stationName,
  stationNotes: stationNotes,
  channel: 'email',
  expiresAt: DateTime.utc(2026, 8, 21, 13),
  seats:
      seats ??
      const [
        LinkedSeat(
          seatLabel: '12A',
          passengerName: 'Aline Massamba',
          payload: 'BEL1.eyJyIjoiTE5LMDAxIn0.c2ln',
        ),
      ],
);

void main() {
  group('the QR is drawn on the server', () {
    // The run-length path is the only clever thing in the renderer, and a QR
    // drawn one module wrong is a QR that scans as something else — or, worse,
    // scans as a valid ticket for a seat nobody bought. So the test decodes
    // the path back into a grid and compares it against the encoder.
    test('the SVG path is the encoder grid, module for module', () {
      const payload = 'BEL1.eyJyIjoiTE5LMDAxIiwicyI6IjEyQSJ9.c2lnbmF0dXJl';
      final svg = QrSvg.render(payload, label: 'seat');
      final image = QrImage(
        QrCode.fromData(
          data: payload,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      );

      final drawn = <String>{};
      final path = RegExp(r'M(\d+) (\d+)h(\d+)v1h-\d+z');
      for (final m in path.allMatches(svg)) {
        final x = int.parse(m.group(1)!);
        final y = int.parse(m.group(2)!);
        final run = int.parse(m.group(3)!);
        for (var i = 0; i < run; i++) {
          drawn.add('${y - QrSvg.quietZone},${x + i - QrSvg.quietZone}');
        }
      }

      final expected = <String>{};
      for (var row = 0; row < image.moduleCount; row++) {
        for (var col = 0; col < image.moduleCount; col++) {
          if (image.isDark(row, col)) expected.add('$row,$col');
        }
      }

      expect(drawn, expected);
      expect(expected, isNotEmpty);
    });

    test('the quiet zone is four modules on every side', () {
      final svg = QrSvg.render('x', label: 'seat');
      final image = QrImage(
        QrCode.fromData(data: 'x', errorCorrectLevel: QrErrorCorrectLevel.M),
      );
      final side = image.moduleCount + 8;
      expect(svg, contains('viewBox="0 0 $side $side"'));
    });

    // A dark-theme QR is a QR the conductor's cheap scanner refuses.
    test('it is black on white, whatever the page around it does', () {
      final svg = QrSvg.render('x', label: 'seat');
      expect(svg, contains('fill="#fff"'));
      expect(svg, contains('fill="#000"'));
    });

    test('a label with markup in it cannot break out of the attribute', () {
      final svg = QrSvg.render('x', label: 'seat "12A" <b>');
      expect(svg, contains('&quot;12A&quot;'));
      expect(svg, isNot(contains('<b>')));
    });
  });

  group('the page a passenger holds up', () {
    test('renders the whole ticket without a single script', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(),
        catalog: _catalog,
      );

      expect(html, contains('Brazzaville'));
      expect(html, contains('Pointe-Noire'));
      expect(html, contains('Océan du Nord'));
      expect(html, contains('BEL-LNK001'));
      expect(html, contains('12A'));
      expect(html, contains('Aline Massamba'));
      expect(html, contains('<svg'));
      // No fetch, no polling, no framework: a browser with scripting off
      // still boards.
      expect(html, isNot(contains('<script')));
      expect(html, isNot(contains('fetch(')));
    });

    test('the words come from the catalog, in both languages', () {
      final fr = BoardingPassPage.render(ticket: _ticket(), catalog: _catalog);
      final en = BoardingPassPage.render(
        ticket: _ticket(),
        catalog: _catalog,
        language: 'en',
      );
      expect(fr, contains('Présentez ce code au conducteur'));
      expect(en, contains('Show this code to the conductor'));
      expect(fr, isNot(contains('boardingPass.')));
      expect(en, isNot(contains('boardingPass.')));
    });

    // Brazzaville is UTC+1 and does not observe daylight saving.
    test('the hours are local, not UTC', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(),
        catalog: _catalog,
      );
      expect(html, contains('20/08 06:00'));
      expect(html, contains('20/08 14:00'));
    });

    test('the yard and the company directions to it are on it', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(),
        catalog: _catalog,
      );
      expect(html, contains('Gare de Mikalou'));
      expect(html, contains('Portail vert'));
    });

    // A roadside stop nobody named says nothing, rather than printing the
    // terminal in Brazzaville the coach left from.
    test('a stop with no yard named prints no yard', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(stationName: null, stationNotes: null),
        catalog: _catalog,
      );
      expect(html, isNot(contains('Gare de départ')));
    });

    test('a cancelled departure says so above the ticket', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(status: 'cancelled'),
        catalog: _catalog,
      );
      expect(html, contains('annulé par la compagnie'));
    });

    // A family of three whose middle ticket was refunded must not find a page
    // with two seats on it and no explanation.
    test('a voided seat is shown and struck through, never dropped', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(
          seats: const [
            LinkedSeat(
              seatLabel: '12A',
              passengerName: 'Aline Massamba',
              payload: 'BEL1.aaa.bbb',
            ),
            LinkedSeat(
              seatLabel: '12B',
              passengerName: 'Serge Massamba',
              payload: 'BEL1.ccc.ddd',
              voided: true,
            ),
          ],
        ),
        catalog: _catalog,
      );

      expect(html, contains('12B'));
      expect(html, contains('Serge Massamba'));
      expect(html, contains('class="ticket dead"'));
      expect(html, contains("Ce billet a été annulé"));
      expect('<svg'.allMatches(html).length, 2);
    });

    test("a passenger's name cannot inject markup", () {
      final html = BoardingPassPage.render(
        ticket: _ticket(
          seats: const [
            LinkedSeat(
              seatLabel: '1A',
              passengerName: '<script>alert(1)</script>',
              payload: 'BEL1.aaa.bbb',
            ),
          ],
        ),
        catalog: _catalog,
      );
      expect(html, isNot(contains('<script')));
      expect(html, contains('&lt;script&gt;'));
    });

    // Revoked, expired and never-issued are one page, because the holder
    // cannot act on the difference.
    test('a dead link renders one kind sentence and no ticket', () {
      final html = BoardingPassPage.renderGone(catalog: _catalog);
      expect(html, contains("Ce lien n'est plus valable"));
      expect(html, isNot(contains('<svg')));
    });
  });
}
