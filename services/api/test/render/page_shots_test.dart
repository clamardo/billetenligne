import 'dart:io';

import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/infrastructure/web/boarding_pass_page.dart';
import 'package:bel_api/src/infrastructure/web/storefront_page.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:test/test.dart';

/// Writes the server-rendered pages to `build/design/` so they can be opened
/// in a browser and looked at.
///
/// Asserts nothing. The same reasoning as the Flutter contact sheets: a page
/// reviewed only by reading the string that builds it is a page nobody has
/// seen, and that is how a shop window ends up as a coloured band.
void main() {
  final catalog = CatalogLoader.fromDirectory(_i18n());
  final out = Directory('build/design')..createSync(recursive: true);

  VitrineDto vitrine({
    String accentHue = 'laterite',
    String headerPattern = 'diagonale',
    String? coverUrl,
  }) => VitrineDto(
    operatorId: 'op-1',
    code: 'ALZ',
    legalName: 'Alizés Transport SARL',
    tradingName: 'Alizés du Congo',
    accentHue: accentHue,
    headerPattern: headerPattern,
    coverUrl: coverUrl,
    taglineFr: 'Le confort sur la nationale 1, depuis 1998.',
  );

  StorefrontRouteDto route(String from, String to, int fare, int hour) =>
      StorefrontRouteDto(
        code: '$from-$to',
        originCity: from,
        destinationCity: to,
        fromFare: Money.xaf(fare),
        nextDepartureAt: DateTime.utc(2026, 8, 15, hour),
      );

  test('storefront', () {
    for (final hue in ['laterite', 'prune', 'ocean']) {
      File('${out.path}/storefront-$hue.html').writeAsStringSync(
        StorefrontPage.render(
          storefront: StorefrontDto(
            vitrine: vitrine(accentHue: hue),
            routes: [
              route('Brazzaville', 'Pointe-Noire', 15000, 6),
              route('Brazzaville', 'Dolisie', 9000, 8),
              route('Pointe-Noire', 'Dolisie', 6000, 14),
            ],
          ),
          catalog: catalog,
          origin: 'https://blt.cg',
        ),
      );
    }

    File('${out.path}/storefront-empty.html').writeAsStringSync(
      StorefrontPage.render(
        storefront: StorefrontDto(vitrine: vitrine(), routes: const []),
        catalog: catalog,
      ),
    );

    File(
      '${out.path}/storefront-unknown.html',
    ).writeAsStringSync(StorefrontPage.notFound(catalog: catalog));
  });

  // The page a traveller sends to whoever is meeting them. Two hues, because
  // the point of the band is that two companies do not look alike.
  test('the boarding pass a link opens', () {
    for (final hue in ['indigo', 'laterite']) {
      File('${out.path}/boarding-pass-$hue.html').writeAsStringSync(
        BoardingPassPage.render(ticket: _linked(hue), catalog: catalog),
      );
    }
  });
}

String _i18n() {
  for (final up in ['..', '../..', '../../..', '.']) {
    final candidate = '$up/packages/bel_localization/i18n';
    if (Directory(candidate).existsSync()) return candidate;
  }
  throw StateError('i18n directory not found');
}

LinkedTicket _linked(String hue) => LinkedTicket(
  bookingRef: 'LNK4821',
  state: 'confirmed',
  operatorName: 'Alizés du Congo',
  operatorCode: 'ALZ',
  operatorAccentHue: hue,
  routeCode: 'BZV-PNR',
  originCity: 'Brazzaville',
  destinationCity: 'Pointe-Noire',
  departsAt: DateTime.utc(2026, 8, 20, 5),
  arrivesAt: DateTime.utc(2026, 8, 20, 13),
  status: 'scheduled',
  stationName: 'Gare de Mikalou',
  stationNotes: 'Portail vert, à côté du marché',
  channel: 'whatsapp',
  expiresAt: DateTime.utc(2026, 8, 21, 13),
  seats: const [
    LinkedSeat(
      seatLabel: '12A',
      passengerName: 'Aline Massamba',
      payload: 'BEL1.eyJyIjoiTE5LNDgyMSJ9.c2ln',
    ),
    LinkedSeat(
      seatLabel: '12B',
      passengerName: 'Joseph Massamba',
      payload: 'BEL1.eyJyIjoiTE5LNDgyMiJ9.c2ln',
    ),
  ],
);
