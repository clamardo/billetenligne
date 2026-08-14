import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/search_screen.dart';
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
}

BookingDto _booking() {
  final departsAt = DateTime.utc(2026, 8, 15, 6);
  return BookingDto(
    id: 'shot',
    ref: 'BEL-4821',
    state: 'confirmed',
    departureId: 'dep-shot',
    operatorName: 'Ocean du Nord',
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
