import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/infrastructure/web/app_link_claims.dart';
import 'package:bel_api/src/infrastructure/web/boarding_pass_page.dart';
import 'package:bel_api/src/infrastructure/web/qr_png.dart';
import 'package:bel_api/src/infrastructure/web/qr_svg.dart';
import 'package:bel_api/src/infrastructure/web/ticket_email.dart';
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
  String? accentHue = 'indigo',
}) => LinkedTicket(
  bookingRef: 'LNK001',
  state: 'confirmed',
  operatorName: 'Océan du Nord',
  operatorCode: 'ODN',
  operatorAccentHue: accentHue,
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

  group('the QR travels to an inbox as a file', () {
    // The one test that matters: a real zlib decoder has to accept the stream,
    // and the pixels it yields have to be the encoder's grid. A PNG that only
    // our own reader can read is a PNG nobody can scan.
    test('a real decoder reads it back, module for module', () {
      const payload = 'BEL1.eyJyIjoiTE5LMDAxIn0.c2ln';
      const scale = 4;
      final png = QrPng.render(payload, scale: scale);
      final image = QrImage(
        QrCode.fromData(
          data: payload,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ),
      );

      expect(png.sublist(0, 8), [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);

      final chunks = _chunks(png);
      final ihdr = chunks['IHDR']!;
      final side = (image.moduleCount + 8) * scale;
      expect(_be32(ihdr, 0), side);
      expect(_be32(ihdr, 4), side);
      expect(ihdr[8], 1, reason: 'one bit per pixel');
      expect(ihdr[9], 0, reason: 'greyscale');

      final raw = ZLibDecoder().convert(chunks['IDAT']!);
      final rowBytes = (side + 7) ~/ 8;
      expect(raw.length, (rowBytes + 1) * side);

      bool pixel(int x, int y) {
        final byte = raw[y * (rowBytes + 1) + 1 + (x >> 3)];
        return (byte & (0x80 >> (x & 7))) == 0; // 0 is black
      }

      for (var row = 0; row < image.moduleCount; row++) {
        for (var col = 0; col < image.moduleCount; col++) {
          final x = (col + 4) * scale;
          final y = (row + 4) * scale;
          expect(
            pixel(x, y),
            image.isDark(row, col),
            reason: 'module $row,$col',
          );
        }
      }
    });

    test('the quiet zone is white all the way round', () {
      final png = QrPng.render('x', scale: 2);
      final chunks = _chunks(png);
      final side = _be32(chunks['IHDR']!, 0);
      final raw = ZLibDecoder().convert(chunks['IDAT']!);
      final rowBytes = (side + 7) ~/ 8;

      for (var y = 0; y < 8; y++) {
        for (var i = 0; i < rowBytes; i++) {
          expect(raw[y * (rowBytes + 1) + 1 + i], 0xFF);
        }
      }
    });

    // Every chunk carries a CRC, and a mail client that finds a bad one shows
    // a broken image rather than a ticket.
    test('every chunk checksums', () {
      final png = QrPng.render('x');
      // _chunks throws on a bad CRC.
      expect(_chunks(png).keys, containsAll(['IHDR', 'IDAT', 'IEND']));
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

  _emailTests();
  _appLinkTests();

  group("the operator's colour", () {
    test('rides on the band and the button', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(),
        catalog: _catalog,
      );

      expect(html, contains('--brand:#1E3A6B'));
      expect(html, contains('class="band"'));
      // The name is still written out. A colour is recognition, not
      // identification, and eight hues across a hundred operators means
      // several companies share one.
      expect(html, contains('Océan du Nord'));
    });

    // An operator who has never opened their vitrine, and a hue from a console
    // that ships separately from this server. Both render; neither is allowed
    // to leave the page without a colour at all.
    test('an unchosen or unknown hue falls back to the house green', () {
      for (final hue in [null, 'turquoise']) {
        final html = BoardingPassPage.render(
          ticket: _ticket(accentHue: hue),
          catalog: _catalog,
        );
        expect(html, contains('--brand:#0A6B4F'), reason: 'hue: $hue');
      }
    });

    // The column has a CHECK constraint behind it, but this page is rendered
    // from whatever the function returned, and a stylesheet is a place where
    // a stray brace ends a rule and starts somebody else's.
    test('a hue is looked up, never interpolated', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(accentHue: 'red;}body{display:none'),
        catalog: _catalog,
      );

      expect(html, isNot(contains('body{display:none')));
      expect(html, isNot(contains('red;}')));
      expect(html, contains('--brand:#0A6B4F'));
    });

    // A yard printer is not owed a full-bleed cartridge of somebody's brand.
    test('the band is dropped for print', () {
      final html = BoardingPassPage.render(
        ticket: _ticket(),
        catalog: _catalog,
      );

      expect(html, contains('@media print'));
      expect(
        html.substring(html.indexOf('@media print')),
        contains('.band{background:#fff'),
      );
    });
  });
}

void _appLinkTests() {
  group('a link that opens the app', () {
    test('Android is told which app, and by which certificate', () {
      final json =
          jsonDecode(
                AppLinkClaims.assetLinks(
                  androidPackage: 'cg.billetenligne.bel_traveller',
                  fingerprints: const ['AA:BB', 'CC:DD'],
                ),
              )
              as List;

      final target = (json.single as Map)['target']! as Map;
      expect((json.single as Map)['relation'], [
        'delegate_permission/common.handle_all_urls',
      ]);
      expect(target['namespace'], 'android_app');
      expect(target['package_name'], 'cg.billetenligne.bel_traveller');
      // Two, because a release build and an upload key are two fingerprints
      // for one app, and forgetting the second is how links stop opening.
      expect(target['sha256_cert_fingerprints'], ['AA:BB', 'CC:DD']);
    });

    // Blank is a supported state: a deployment with no store listing serves a
    // well-formed file with nothing in it, rather than a 404 that sends
    // somebody looking at DNS.
    test('and with no certificate it is still well formed', () {
      final json =
          jsonDecode(
                AppLinkClaims.assetLinks(
                  androidPackage: 'cg.billetenligne.bel_traveller',
                  fingerprints: const [],
                ),
              )
              as List;
      expect(
        ((json.single as Map)['target']! as Map)['sha256_cert_fingerprints'],
        isEmpty,
      );
    });

    test('iOS is told the app claims the ticket path and no other', () {
      final json =
          jsonDecode(
                AppLinkClaims.appleAppSiteAssociation(
                  appleAppId: 'TEAM.bundle',
                ),
              )
              as Map;

      final details =
          ((json['applinks']! as Map)['details']! as List).single as Map;
      expect(details['appIDs'], ['TEAM.bundle']);
      // `/t/` is the follower page, opened by strangers with no app. An
      // operating system offering to install one would be answering a
      // question nobody asked.
      expect(((details['components']! as List).single as Map)['/'], '/b/*');
    });

    test('an empty environment claims nothing, and says so', () {
      final blank = AppLinkIdentity.from(const {});
      expect(blank.androidFingerprints, isEmpty);
      expect(blank.appleAppId, '');
      expect(blank.isClaimed, isFalse);
    });

    test('fingerprints are split, trimmed and upper-cased', () {
      final identity = AppLinkIdentity.from(const {
        'BEL__ANDROIDFINGERPRINTS': 'aa:bb , cc:dd ,',
        'BEL__APPLEAPPID': 'TEAM.bundle',
      });
      expect(identity.androidFingerprints, ['AA:BB', 'CC:DD']);
      expect(identity.isClaimed, isTrue);
    });
  });
}

void _emailTests() {
  group('the ticket in an inbox', () {
    String render({
      String? stationName = 'Gare de Mikalou',
      String? stationNotes = 'Portail vert',
      List<EmailedSeat> seats = const [
        EmailedSeat(seatLabel: '12A', passengerName: 'Aline Massamba'),
      ],
      String language = 'fr',
    }) => TicketEmail.render(
      originCity: 'Brazzaville',
      destinationCity: 'Pointe-Noire',
      operatorName: 'Océan du Nord',
      date: '20/08',
      time: '06h00',
      reference: 'BEL-LNK001',
      seats: seats,
      url: 'https://blt.cg/b/abc123',
      catalog: _catalog,
      stationName: stationName,
      stationNotes: stationNotes,
      language: language,
    );

    test('carries everything somebody needs to board', () {
      final html = render();
      expect(html, contains('Brazzaville'));
      expect(html, contains('Pointe-Noire'));
      expect(html, contains('Océan du Nord'));
      expect(html, contains('20/08'));
      expect(html, contains('06h00'));
      expect(html, contains('BEL-LNK001'));
      expect(html, contains('12A'));
      expect(html, contains('Aline Massamba'));
      expect(html, contains('Gare de Mikalou'));
      expect(html, contains('Portail vert'));
      expect(html, contains('https://blt.cg/b/abc123'));
    });

    // A link that only exists inside a button is a link nobody can copy into
    // another browser, which is what somebody does when the button does
    // nothing in their mail client.
    test('the URL is written out as well as linked', () {
      final html = render();
      expect('https://blt.cg/b/abc123'.allMatches(html).length, 2);
    });

    test('it says the codes are attached, in both languages', () {
      expect(render(), contains('joints à ce message'));
      expect(render(language: 'en'), contains('attached to this message'));
    });

    // No stylesheet survives Gmail.
    test('every style is inline, because email has no stylesheet', () {
      expect(render(), isNot(contains('<style')));
      expect(render(), contains('style="'));
    });

    test('a yard nobody named prints no yard', () {
      final html = render(stationName: null, stationNotes: null);
      expect(html, isNot(contains('Gare de départ')));
    });

    test("a passenger's name cannot inject markup", () {
      final html = render(
        seats: const [EmailedSeat(seatLabel: '1A', passengerName: '<b>x</b>')],
      );
      expect(html, contains('&lt;b&gt;'));
    });
  });
}

int _be32(List<int> bytes, int at) =>
    (bytes[at] << 24) |
    (bytes[at + 1] << 16) |
    (bytes[at + 2] << 8) |
    bytes[at + 3];

/// Chunk name to payload, verifying each CRC on the way through — so a
/// malformed file fails here rather than in somebody's mail client.
Map<String, Uint8List> _chunks(Uint8List png) {
  final out = <String, Uint8List>{};
  var at = 8;
  while (at < png.length) {
    final length = _be32(png, at);
    final name = String.fromCharCodes(png.sublist(at + 4, at + 8));
    final body = png.sublist(at + 8, at + 8 + length);
    final crc = _be32(png, at + 8 + length);
    if (crc != _crc32(png.sublist(at + 4, at + 8 + length))) {
      throw StateError('bad CRC on $name');
    }
    out[name] = Uint8List.fromList([...?out[name], ...body]);
    at += 12 + length;
  }
  return out;
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    var c = (crc ^ byte) & 0xFF;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    crc = c ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
