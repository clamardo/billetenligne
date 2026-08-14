import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/ticket_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// The ticket is the one screen a passenger holds up to a conductor, and a
/// conductor knows their own company's colour from further away than they can
/// read a name. These tests exist because the hue had a column, a CHECK
/// constraint and eight curated values behind it, and still arrived at the
/// ticket as nothing — every ticket in the house green.
void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  Widget host(BookingDto booking) => MaterialApp(
    theme: KiloTheme.materialTheme(brightness: KiloBrightness.light),
    home: Localized(
      catalog: catalog,
      initialLanguage: 'fr',
      child: TicketScreen(
        booking: booking,
        ticket: booking.tickets.single,
        seatIndex: 0,
        onClose: () {},
      ),
    ),
  );

  testWidgets('the operator\'s own hue reaches the ticket band', (
    tester,
  ) async {
    await tester.pumpWidget(host(_booking('indigo')));
    await tester.pump();

    final header = tester.widget<KTicketHeader>(find.byType(KTicketHeader));
    expect(header.accent, AccentHue.indigo);
  });

  testWidgets('an operator who never opened the vitrine gets the house green', (
    tester,
  ) async {
    await tester.pumpWidget(host(_booking(null)));
    await tester.pump();

    final header = tester.widget<KTicketHeader>(find.byType(KTicketHeader));
    expect(header.accent, isNull);
  });

  // A hue this build has never heard of must not blank the band or throw. The
  // column is edited by a console that ships separately from this app, so a
  // ninth hue is a question of when.
  testWidgets('a hue from a newer console falls back rather than throwing', (
    tester,
  ) async {
    await tester.pumpWidget(host(_booking('turquoise')));
    await tester.pump();

    final header = tester.widget<KTicketHeader>(find.byType(KTicketHeader));
    expect(header.accent, isNull);
    expect(find.byType(KTicketHeader), findsOneWidget);
  });
}

BookingDto _booking(String? hue) {
  final departsAt = DateTime.utc(2026, 8, 15, 6);
  return BookingDto(
    id: 'bk',
    ref: 'BEL-4821',
    state: 'confirmed',
    departureId: 'dep',
    operatorName: 'Ocean du Nord',
    operatorAccentHue: hue,
    originCity: 'Brazzaville',
    destinationCity: 'Pointe-Noire',
    departsAt: departsAt,
    arrivesAt: departsAt.add(const Duration(hours: 8)),
    passengers: const [PassengerDto(fullName: 'Aline M.', seatLabel: '14A')],
    total: const Money.xaf(12300),
    createdAt: departsAt.subtract(const Duration(days: 1)),
    tickets: [
      TicketDto(
        id: 'tk',
        bookingRef: 'BEL-4821',
        seatLabel: '14A',
        passengerName: 'Aline M.',
        qrPayload: 'BEL1.bk.14A.signature',
        rotatingSecret: 'demo',
        keyId: 1,
        issuedAt: departsAt.subtract(const Duration(days: 1)),
      ),
    ],
  );
}
