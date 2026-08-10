import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/application/tickets_flow.dart';
import 'package:bel_traveller/src/presentation/screens/ticket_screen.dart';
import 'package:bel_traveller/src/presentation/screens/tickets_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'booking_flow_test.dart' show ScriptedGatewayFactory;
import 'catalog_fixture.dart';

final class _FixedClock implements Clock {
  _FixedClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void set(DateTime at) => _now = at;
}

/// `demo` is four base64 characters — three bytes — which is a perfectly
/// usable HMAC key and keeps the fixture readable.
BookingDto _booking({
  required String id,
  required DateTime departsAt,
  String state = 'confirmed',
  bool withTicket = true,
  int seats = 1,
  DateTime? voidedAt,
}) => BookingDto(
  id: id,
  ref: 'BEL-$id',
  state: state,
  departureId: 'dep-$id',
  operatorName: 'Ocean du Nord',
  originCity: 'Brazzaville',
  destinationCity: 'Pointe-Noire',
  departsAt: departsAt,
  arrivesAt: departsAt.add(const Duration(hours: 8)),
  passengers: [
    for (var i = 0; i < seats; i++)
      PassengerDto(fullName: 'Aline M.', seatLabel: '${i + 1}A'),
  ],
  fare: const Money.xaf(12000),
  serviceFee: const Money.xaf(300),
  total: const Money.xaf(12300),
  createdAt: departsAt.subtract(const Duration(days: 1)),
  paymentCode: state == 'confirmed' ? null : 'K4M2Q',
  paymentDeadline: state == 'confirmed'
      ? null
      : departsAt.subtract(const Duration(hours: 4)),
  tickets: [
    if (withTicket)
      for (var i = 0; i < seats; i++)
        TicketDto(
          id: 'tk-$id-$i',
          bookingRef: 'BEL-$id',
          seatLabel: '${i + 1}A',
          passengerName: 'Aline M.',
          qrPayload: 'BEL1.$id.${i + 1}A.signature',
          rotatingSecret: 'demo',
          keyId: 1,
          issuedAt: departsAt.subtract(const Duration(days: 1)),
          voidedAt: voidedAt,
        ),
  ],
);

void main() {
  late ScriptedGatewayFactory gateway;
  late _FixedClock clock;
  late TicketsFlow flow;

  final now = DateTime.utc(2026, 8, 10, 6);

  setUp(() {
    gateway = ScriptedGatewayFactory();
    clock = _FixedClock(now);
    flow = TicketsFlow(gateway: gateway, clock: clock);
  });

  group('the list', () {
    test('puts the next departure first and history behind it', () async {
      gateway.bookingsResult = [
        _booking(id: 'later', departsAt: now.add(const Duration(days: 3))),
        _booking(id: 'soon', departsAt: now.add(const Duration(hours: 2))),
        _booking(id: 'gone', departsAt: now.subtract(const Duration(days: 4))),
        _booking(id: 'older', departsAt: now.subtract(const Duration(days: 9))),
      ];

      await flow.load();

      final step = flow.step as TicketsReady;
      // Somebody at a station at 05:40 wants the 06:00 coach at the top and
      // nothing else in the way.
      expect(step.upcoming.map((b) => b.id), ['soon', 'later']);
      expect(step.past.map((b) => b.id), ['gone', 'older']);
    });

    test('an unpaid reservation is listed, not hidden', () async {
      gateway.bookingsResult = [
        _booking(
          id: 'unpaid',
          departsAt: now.add(const Duration(days: 1)),
          state: 'pending_payment',
          withTicket: false,
        ),
      ];

      await flow.load();

      final step = flow.step as TicketsReady;
      // "Where is the code I was given?" is the other question this screen
      // exists to answer.
      expect(step.upcoming.single.paymentCode, 'K4M2Q');
    });

    test('a cancelled trip still ahead stays with the upcoming', () async {
      // The departure decides, not the state. A trip cancelled for tomorrow
      // is the thing somebody has to act on today.
      gateway.bookingsResult = [
        _booking(
          id: 'off',
          departsAt: now.add(const Duration(days: 1)),
          state: 'cancelled',
          withTicket: false,
        ),
      ];

      await flow.load();
      expect((flow.step as TicketsReady).upcoming, hasLength(1));
    });

    test('a failed refresh keeps the tickets already loaded', () async {
      gateway.bookingsResult = [
        _booking(id: 'held', departsAt: now.add(const Duration(hours: 2))),
      ];
      await flow.load();

      gateway.bookingsFailure = const NetworkUnreachable();
      await flow.refresh();

      final step = flow.step as TicketsReady;
      // The traveller is standing at the door either way, and a ticket loaded
      // an hour ago beats an apology.
      expect(step.upcoming, hasLength(1));
      expect(step.stale, isTrue);
    });

    test('a first load that fails has nothing to show, and says so', () async {
      gateway.bookingsFailure = const NetworkUnreachable();
      await flow.load();
      expect(flow.step, isA<TicketsFailed>());
    });
  });

  group('opening a ticket', () {
    test('refuses a booking with no ticket to open', () async {
      final unpaid = _booking(
        id: 'unpaid',
        departsAt: now.add(const Duration(days: 1)),
        state: 'pending_payment',
        withTicket: false,
      );
      gateway.bookingsResult = [unpaid];
      await flow.load();

      flow.open(unpaid);

      // No ticket exists — the money has not moved — and a screen that
      // pretended otherwise is the most confusing thing this flow could do.
      expect(flow.step, isA<TicketsReady>());
    });

    test('walks the seats of one booking, and wraps', () async {
      final family = _booking(
        id: 'family',
        departsAt: now.add(const Duration(hours: 2)),
        seats: 3,
      );
      gateway.bookingsResult = [family];
      await flow.load();

      flow.open(family);
      expect((flow.step as ViewingTicket).ticket!.seatLabel, '1A');

      flow.showSeat(1);
      expect((flow.step as ViewingTicket).ticket!.seatLabel, '2A');

      // Wraps rather than dead-ends: four seats and a dead end at the fourth
      // is a conductor waiting while somebody taps back.
      flow.showSeat(3);
      expect((flow.step as ViewingTicket).ticket!.seatLabel, '1A');
    });

    test('a receipt goes straight to the ticket it paid for', () async {
      gateway.bookingsResult = [
        _booking(id: 'other', departsAt: now.add(const Duration(days: 2))),
        _booking(id: 'paid', departsAt: now.add(const Duration(hours: 3))),
      ];

      await flow.loadAndOpen('paid');

      final step = flow.step as ViewingTicket;
      expect(step.booking.id, 'paid');
    });
  });

  group('the ticket screen', () {
    testWidgets('renders the QR and a live six-digit code', (tester) async {
      final catalog = await loadTestCatalog();
      final booking = _booking(
        id: 'live',
        departsAt: now.add(const Duration(hours: 2)),
      );

      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TicketScreen(
              booking: booking,
              ticket: booking.tickets.single,
              seatIndex: 0,
              onClose: () {},
              clock: clock,
            ),
          ),
        ),
      );

      expect(find.byType(QrImageView), findsOneWidget);

      // Six digits, grouped in threes — read aloud across a noisy platform in
      // two halves.
      final code = RotatingCode.current(
        secret: booking.tickets.single.rotatingSecretBytes,
        now: now,
        mac: const HmacSha256Authenticator(),
      );
      expect(
        find.text('${code.substring(0, 3)} ${code.substring(3)}'),
        findsOneWidget,
      );
    });

    testWidgets('a void ticket says so and still shows', (tester) async {
      final catalog = await loadTestCatalog();
      final booking = _booking(
        id: 'void',
        departsAt: now.add(const Duration(hours: 2)),
        voidedAt: now.subtract(const Duration(days: 1)),
      );

      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TicketScreen(
              booking: booking,
              ticket: booking.tickets.single,
              seatIndex: 0,
              onClose: () {},
              clock: clock,
            ),
          ),
        ),
      );

      // Still rendered. A refunded ticket that silently vanishes reads as our
      // bug at the worst possible moment.
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.text(
          CatalogTranslator(catalog, 'fr')('travel.ticket.voidedTitle'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a disrupted coach says so above the code', (tester) async {
      final catalog = await loadTestCatalog();
      final base = _booking(
        id: 'broken',
        departsAt: now.add(const Duration(hours: 2)),
      );
      final booking = BookingDto(
        id: base.id,
        ref: base.ref,
        state: base.state,
        departureId: base.departureId,
        operatorName: base.operatorName,
        originCity: base.originCity,
        destinationCity: base.destinationCity,
        departsAt: base.departsAt,
        arrivesAt: base.arrivesAt,
        passengers: base.passengers,
        total: base.total,
        createdAt: base.createdAt,
        tickets: base.tickets,
        involuntaryChange: true,
        disruption: DisruptionDto(
          id: 'd-1',
          kind: DisruptionKind.breakdownEnRoute,
          cause: DisruptionCause.mechanical,
          declaredAt: now,
          marksInvoluntary: true,
          location: 'RN1 près de Dolisie',
          note: 'pont coupé',
        ),
      );

      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TicketScreen(
              booking: booking,
              ticket: booking.tickets.single,
              seatIndex: 0,
              onClose: () {},
              clock: clock,
            ),
          ),
        ),
      );

      // During a breakdown the ticket is the information channel: what
      // happened, where, in the operator's own words — and that it costs
      // nothing, which is the first question anybody has.
      expect(find.textContaining('Panne en route'), findsOneWidget);
      expect(find.textContaining('RN1 près de Dolisie'), findsOneWidget);
      expect(find.text('pont coupé'), findsOneWidget);
      expect(find.textContaining('Aucun frais'), findsOneWidget);
      // And the ticket still works. It is still a valid ticket for a coach
      // that is going to run late, and hiding the QR would strand somebody
      // who decides to wait.
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('a short delay carries the new time and no promise', (
      tester,
    ) async {
      final catalog = await loadTestCatalog();
      final base = _booking(
        id: 'late',
        departsAt: now.add(const Duration(hours: 2)),
      );
      final booking = BookingDto(
        id: base.id,
        ref: base.ref,
        state: base.state,
        departureId: base.departureId,
        operatorName: base.operatorName,
        originCity: base.originCity,
        destinationCity: base.destinationCity,
        departsAt: base.departsAt,
        arrivesAt: base.arrivesAt,
        passengers: base.passengers,
        total: base.total,
        createdAt: base.createdAt,
        tickets: base.tickets,
        disruption: DisruptionDto(
          id: 'd-2',
          kind: DisruptionKind.delay,
          cause: DisruptionCause.checkpoint,
          declaredAt: now,
          marksInvoluntary: false,
          revisedDepartsAt: base.departsAt.add(const Duration(minutes: 20)),
        ),
      );

      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TicketScreen(
              booking: booking,
              ticket: booking.tickets.single,
              seatIndex: 0,
              onClose: () {},
              clock: clock,
            ),
          ),
        ),
      );

      // A time, not a delay: "+20 min" is arithmetic somebody does standing
      // at a roadside at 04:00.
      expect(find.textContaining('09:20'), findsOneWidget);
      // And no free-refund promise the counter would have to refuse.
      expect(find.textContaining('Aucun frais'), findsNothing);
    });

    testWidgets('an empty list offers a search rather than a blank', (
      tester,
    ) async {
      final catalog = await loadTestCatalog();

      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TicketsScreen(
              upcoming: const [],
              past: const [],
              onOpen: (_) {},
              onBack: () {},
              onRefresh: () async {},
              onSearch: () {},
            ),
          ),
        ),
      );

      expect(
        find.text(
          CatalogTranslator(catalog, 'fr')('travel.tickets.emptyTitle'),
        ),
        findsOneWidget,
      );
    });
  });
}
