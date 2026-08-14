import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/results_screen.dart';
import 'package:bel_traveller/src/presentation/screens/search_screen.dart';
import 'package:bel_traveller/src/presentation/screens/seat_map_screen.dart';
import 'package:bel_traveller/src/presentation/screens/ticket_screen.dart';
import 'package:bel_traveller/src/presentation/screens/tickets_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog_fixture.dart';
import 'render_harness.dart';

/// Renders whole screens to `build/design/` so the design can be looked at.
/// Asserts nothing; see the note in `render_harness.dart`.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  const cities = [
    CityOption('BZV', 'Brazzaville'),
    CityOption('PNR', 'Pointe-Noire'),
    CityOption('DOL', 'Dolisie'),
  ];

  testWidgets('search on the narrowest handset', (tester) async {
    await shoot(
      tester,
      'traveller-search-narrow',
      Localized(
        catalog: catalog,
        initialLanguage: 'fr',
        child: SearchScreen(
          cities: cities,
          onSearch: (_) {},
          onOpenTickets: () {},
        ),
      ),
      size: const Size(320, 560),
    );
  });

  for (final b in [KiloBrightness.light, KiloBrightness.dark]) {
    testWidgets('search ${b.name}', (tester) async {
      await shoot(
        tester,
        'traveller-search-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: SearchScreen(
            cities: cities,
            onSearch: (_) {},
            onOpenTickets: () {},
          ),
        ),
        size: const Size(400, 860),
        brightness: b,
      );
    });

    testWidgets('empty tickets ${b.name}', (tester) async {
      await shoot(
        tester,
        'traveller-tickets-empty-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: TicketsScreen(
            upcoming: const [],
            past: const [],
            onBack: () {},
            onOpen: (_) {},
            onRefresh: () async {},
            onSearch: () {},
            onChoices: (_) {},
            onCancel: (_) {},
            onChange: (_) {},
          ),
        ),
        size: const Size(400, 860),
        brightness: b,
      );
    });
  }

  for (final b in [KiloBrightness.light, KiloBrightness.dark]) {
    testWidgets('ticket ${b.name}', (tester) async {
      final booking = _booking();
      await shoot(
        tester,
        'traveller-ticket-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: TicketScreen(
            booking: booking,
            ticket: booking.tickets.single,
            seatIndex: 0,
            onClose: () {},
          ),
        ),
        size: const Size(400, 900),
        brightness: b,
      );
    });
  }

  // The coach itself, which is the screen the whole funnel narrows to and the
  // only one where a traveller is looking at a picture rather than a list.
  // Three states in one frame: taken, chosen, and the last row still free.
  for (final b in [KiloBrightness.light, KiloBrightness.dark]) {
    testWidgets('seat map ${b.name}', (tester) async {
      await shoot(
        tester,
        'traveller-seats-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: SeatMapScreen(
            departure: _departure('dep-shot', 6, 21),
            seatMap: _seatMap(),
            selected: const {'2C'},
            onToggle: (_) {},
            onContinue: () {},
            onBack: () {},
          ),
        ),
        size: const Size(400, 900),
        brightness: b,
      );
    });
  }

  // The hue the ink fix is about. `laterite` is a light ochre: white on it is
  // 3.17:1, which is enough for the route name across the top and not enough
  // for the date under it — the line somebody reads at a coach door. This
  // band is drawn in the dark ink, and it is worth being able to look at.
  testWidgets('ticket on the one hue that does not carry white', (
    tester,
  ) async {
    final booking = _booking(hue: 'laterite');
    await shoot(
      tester,
      'traveller-ticket-laterite',
      Localized(
        catalog: catalog,
        initialLanguage: 'fr',
        child: TicketScreen(
          booking: booking,
          ticket: booking.tickets.single,
          seatIndex: 0,
          onClose: () {},
        ),
      ),
      size: const Size(400, 900),
    );
  });

  for (final b in [KiloBrightness.light, KiloBrightness.dark]) {
    testWidgets('results ${b.name}', (tester) async {
      await shoot(
        tester,
        'traveller-results-${b.name}',
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: ResultsScreen(
            query: SearchDeparturesQuery(
              originCity: 'BZV',
              destinationCity: 'PNR',
              date: DateTime.utc(2026, 8, 15),
              passengers: 1,
            ),
            departures: [
              _departure('dep-1', 6, 40),
              _departure('dep-2', 9, 3),
              _departure('dep-3', 14, 0),
            ],
            onSelect: (_) {},
            onBack: () {},
            cityNames: const {'BZV': 'Brazzaville', 'PNR': 'Pointe-Noire'},
          ),
        ),
        size: const Size(400, 860),
        brightness: b,
      );
    });
  }
}

BookingDto _booking({String hue = 'indigo'}) {
  final departsAt = DateTime.utc(2026, 8, 15, 6);
  return BookingDto(
    id: 'shot',
    ref: 'BEL-4821',
    state: 'confirmed',
    departureId: 'dep-shot',
    operatorName: 'Ocean du Nord',
    operatorAccentHue: hue,
    originCity: 'Brazzaville',
    destinationCity: 'Pointe-Noire',
    departsAt: departsAt,
    arrivesAt: departsAt.add(const Duration(hours: 8)),
    passengers: const [PassengerDto(fullName: 'Aline M.', seatLabel: '14A')],
    fare: const Money.xaf(12000),
    serviceFee: const Money.xaf(300),
    total: const Money.xaf(12300),
    createdAt: departsAt.subtract(const Duration(days: 1)),
    tickets: [
      TicketDto(
        id: 'tk-shot',
        bookingRef: 'BEL-4821',
        seatLabel: '14A',
        passengerName: 'Aline M.',
        qrPayload: 'BEL1.shot.14A.signature',
        rotatingSecret: 'demo',
        keyId: 1,
        issuedAt: departsAt.subtract(const Duration(days: 1)),
      ),
    ],
  );
}

DepartureSummaryDto _departure(String id, int hour, int available) =>
    DepartureSummaryDto(
      id: id,
      operatorId: 'op-1',
      operatorName: 'Ocean du Nord',
      mode: 'bus',
      originCity: 'BZV',
      destinationCity: 'PNR',
      departsAt: DateTime.utc(2026, 8, 15, hour),
      arrivesAt: DateTime.utc(2026, 8, 15, hour + 8),
      fare: const Money.xaf(12000),
      serviceFee: const Money.xaf(300),
      seatsAvailable: available,
      capacity: 52,
      seatSelectionEnabled: true,
    );

SeatMapDto _seatMap() => SeatMapDto(
  departureId: 'dep-shot',
  mode: 'bus',
  layoutVersion: 1,
  sections: const [
    CabinSectionDto(
      code: 'STD',
      labelKey: 'seat.class.standard',
      rows: 8,
      abreast: '2+2',
    ),
  ],
  seats: [
    for (var row = 1; row <= 8; row++)
      for (final col in const ['A', 'B', 'C', 'D'])
        SeatDto(
          label: '$row$col',
          sectionCode: 'STD',
          // A coach nobody has bought a seat on is not a coach anybody sees.
          status: row < 3 && col != 'C'
              ? SeatStatusDto.sold
              : row == 4 && col == 'A'
              ? SeatStatusDto.held
              : SeatStatusDto.available,
          fare: const Money.xaf(12000),
        ),
  ],
);
