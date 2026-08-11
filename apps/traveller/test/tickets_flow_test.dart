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
import 'package:bel_traveller/src/presentation/screens/travel_choice_screen.dart';
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
              onChoices: (_) {},
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

  // ── The passenger's own choice ──────────────────────────────────────────

  TravelChoicesDto choicesFor({
    bool open = true,
    int seatsNeeded = 1,
    List<TravelChoiceDto>? options,
  }) => TravelChoicesDto(
    bookingRef: 'BEL-broken',
    seatsNeeded: seatsNeeded,
    originCity: 'Brazzaville',
    destinationCity: 'Pointe-Noire',
    deadline: now.add(const Duration(hours: 4)),
    open: open,
    reasonKey: 'enum.DisruptionCause.mechanical',
    note: 'Panne moteur. Un car de secours part a 11h30.',
    options:
        options ??
        [
          TravelChoiceDto(
            id: 'keep',
            kind: 'keep',
            assigned: true,
            departureId: 'dep-rescue',
            departsAt: now.add(const Duration(hours: 5, minutes: 30)),
            arrivesAt: now.add(const Duration(hours: 12, minutes: 10)),
            seatLabels: const ['14A'],
          ),
          TravelChoiceDto(
            id: 'dep-later',
            kind: 'move',
            assigned: false,
            departureId: 'dep-later',
            departsAt: now.add(const Duration(hours: 8)),
            arrivesAt: now.add(const Duration(hours: 15, minutes: 30)),
            seatsAvailable: 18,
          ),
          const TravelChoiceDto(
            id: 'refund',
            kind: 'refund',
            assigned: false,
            amount: Money.xaf(9300),
          ),
        ],
  );

  group("the passenger's own choice", () {
    test('the options are read at the moment the screen opens', () async {
      gateway.bookingsResult = [
        _booking(id: 'broken', departsAt: now.add(const Duration(hours: 2))),
      ];
      await flow.load();
      final booking = (flow.step as TicketsReady).upcoming.single;

      gateway.choicesResult = choicesFor();
      await flow.openChoices(booking);

      // Never cached. The seat counts are the whole point of the screen, and
      // a cached one offers a coach that filled ten minutes ago.
      expect(gateway.choicesAsked, ['BEL-broken']);
      expect((flow.step as ChoosingTravel).choices.options, hasLength(3));
    });

    test('choosing applies it and reloads the list behind', () async {
      gateway.bookingsResult = [
        _booking(id: 'broken', departsAt: now.add(const Duration(hours: 2))),
      ];
      await flow.load();
      final loads = gateway.bookingsCalls;

      gateway.choicesResult = choicesFor();
      await flow.openChoices((flow.step as TicketsReady).upcoming.single);

      gateway.chooseResult = ChoiceAppliedDto(
        bookingRef: 'BEL-broken',
        kind: 'move',
        departureId: 'dep-later',
        departsAt: now.add(const Duration(hours: 8)),
        seatLabels: const ['22B'],
      );
      await flow.choose('dep-later');

      expect(gateway.chosen, ['dep-later']);
      final step = flow.step as TravelChosen;
      expect(step.applied.seatLabels, ['22B']);
      // The list behind is now wrong — a moved booking is on another coach —
      // so it was re-read before the passenger can get back to it.
      expect(gateway.bookingsCalls, loads + 1);
    });

    test('a second tap while the first is in flight does nothing', () async {
      gateway.bookingsResult = [
        _booking(id: 'broken', departsAt: now.add(const Duration(hours: 2))),
      ];
      await flow.load();
      gateway.choicesResult = choicesFor();
      await flow.openChoices((flow.step as TicketsReady).upcoming.single);

      final first = flow.choose('dep-later');
      // Same turn, before the first has resolved: the screen is showing
      // disabled buttons, but a fast double tap must not reach the server
      // twice and move somebody's seat twice.
      await flow.choose('refund');
      await first;

      expect(gateway.chosen, ['dep-later']);
    });

    test('a refusal re-reads the options rather than stopping', () async {
      gateway.bookingsResult = [
        _booking(id: 'broken', departsAt: now.add(const Duration(hours: 2))),
      ];
      await flow.load();
      gateway.choicesResult = choicesFor();
      await flow.openChoices((flow.step as TicketsReady).upcoming.single);

      // The coach filled between the screen rendering and the tap — which is
      // the common case during a breakdown, not an edge one.
      gateway.chooseFailure = const ServerRefused(
        409,
        ApiError(code: 'choice.no_longer_available'),
      );
      gateway.choicesResult = choicesFor(
        options: [
          TravelChoiceDto(
            id: 'keep',
            kind: 'keep',
            assigned: true,
            departsAt: now.add(const Duration(hours: 5)),
            arrivesAt: now.add(const Duration(hours: 12)),
            seatLabels: const ['14A'],
          ),
        ],
      );
      await flow.choose('dep-later');

      // Still on the options, freshly read, with the refusal above them. The
      // passenger's next move is to look at what is left, not to read an
      // apology on a blank screen.
      final refreshed = flow.step as ChoosingTravel;
      expect(refreshed.busy, isFalse);
      expect(refreshed.choices.alternatives, isEmpty);
      expect(
        refreshed.failure?.messageKey,
        'errors.choice.no_longer_available',
      );
    });

    test(
      'options that cannot be read at all are an error, not a blank',
      () async {
        gateway.bookingsResult = [
          _booking(id: 'broken', departsAt: now.add(const Duration(hours: 2))),
        ];
        await flow.load();
        final booking = (flow.step as TicketsReady).upcoming.single;

        gateway.choicesFailure = const NetworkUnreachable();
        await flow.openChoices(booking);

        expect(flow.step, isA<TicketsFailed>());
      },
    );

    test('closing goes back to the list, re-derived', () async {
      gateway.bookingsResult = [
        _booking(id: 'broken', departsAt: now.add(const Duration(hours: 2))),
      ];
      await flow.load();
      gateway.choicesResult = choicesFor();
      await flow.openChoices((flow.step as TicketsReady).upcoming.single);

      flow.closeChoices();

      expect(flow.step, isA<TicketsReady>());
    });
  });

  group('the choice screen', () {
    Future<void> pump(
      WidgetTester tester,
      TravelChoicesDto choices, {
      void Function(String)? onChoose,
      bool busy = false,
      ApiFailure? failure,
    }) async {
      final catalog = await loadTestCatalog();
      // Tall enough that the whole screen is laid out: "le remboursement est
      // en dernier" is an assertion about order, and it cannot be made
      // against rows a short viewport never built.
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TravelChoiceScreen(
              choices: choices,
              busy: busy,
              failure: failure,
              onChoose: onChoose ?? (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('one option is already theirs, and says so', (tester) async {
      await pump(tester, choicesFor());

      // Nobody is left with nothing while they decide. The assigned row is
      // marked and its button keeps rather than chooses.
      expect(find.text('ATTRIBUÉ'), findsOneWidget);
      expect(find.text('Je garde'), findsOneWidget);
      expect(find.textContaining('siège 14A'), findsOneWidget);
      // And it says what silence means.
      expect(find.textContaining('Sans réponse avant'), findsOneWidget);
    });

    testWidgets('every travel row states the arrival time', (tester) async {
      await pump(tester, choicesFor());

      // The question the passenger is actually asking. 06:00 + 12 h 10 and
      // 06:00 + 15 h 30, in Brazzaville time.
      expect(find.textContaining('Arrivée 19:10'), findsOneWidget);
      expect(find.textContaining('Arrivée 22:30'), findsOneWidget);
    });

    testWidgets('the refund is last and never hidden', (tester) async {
      await pump(tester, choicesFor());

      expect(find.text('Remboursement intégral'), findsOneWidget);
      expect(find.textContaining('9 300'), findsOneWidget);
      // Last on the screen, under both travel options.
      final refund = tester.getTopLeft(find.text('Remboursement intégral')).dy;
      final alt = tester.getTopLeft(find.text('Départ de 15:00')).dy;
      expect(refund, greaterThan(alt));
    });

    testWidgets('a tap sends the option id', (tester) async {
      final taps = <String>[];
      await pump(tester, choicesFor(), onChoose: taps.add);

      await tester.tap(find.text('Choisir').first);
      await tester.pump();

      expect(taps, ['dep-later']);
    });

    testWidgets('a closed window still renders, with nothing to press', (
      tester,
    ) async {
      await pump(tester, choicesFor(open: false));

      // Somebody who follows an SMS link and finds a blank page assumes the
      // worst, and the worst is usually not what happened.
      expect(
        find.textContaining('Le délai de choix est passé'),
        findsOneWidget,
      );
      expect(find.text('Remboursement intégral'), findsOneWidget);
      final buttons = tester.widgetList<KButton>(find.byType(KButton));
      expect(buttons.every((b) => b.onPressed == null), isTrue);
    });

    testWidgets('a coach that filled is shown and disabled, not dropped', (
      tester,
    ) async {
      await pump(
        tester,
        choicesFor(
          options: [
            TravelChoiceDto(
              id: 'keep',
              kind: 'keep',
              assigned: true,
              departsAt: now.add(const Duration(hours: 5)),
              arrivesAt: now.add(const Duration(hours: 12)),
              seatLabels: const ['14A'],
            ),
            TravelChoiceDto(
              id: 'dep-full',
              kind: 'move',
              assigned: false,
              departsAt: now.add(const Duration(hours: 8)),
              arrivesAt: now.add(const Duration(hours: 15)),
              seatsAvailable: 0,
            ),
          ],
        ),
      );

      // A list that quietly shortens between two glances looks like our bug.
      expect(find.text('Complet'), findsOneWidget);
      final choose = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Choisir'),
      );
      expect(choose.onPressed, isNull);
    });

    testWidgets('a party that does not all fit says how many do', (
      tester,
    ) async {
      await pump(
        tester,
        choicesFor(
          seatsNeeded: 5,
          options: [
            TravelChoiceDto(
              id: 'dep-two',
              kind: 'move',
              assigned: false,
              departsAt: now.add(const Duration(hours: 8)),
              arrivesAt: now.add(const Duration(hours: 15)),
              seatsAvailable: 2,
            ),
          ],
        ),
      );

      // The arithmetic belongs on the screen, not in the head of somebody
      // standing on a roadside with three children.
      expect(find.text('2 places sur 5'), findsOneWidget);
    });

    testWidgets("another company's coach is named as one", (tester) async {
      await pump(
        tester,
        choicesFor(
          options: [
            TravelChoiceDto(
              id: 'dep-bony',
              kind: 'move',
              assigned: false,
              departsAt: now.add(const Duration(hours: 6)),
              arrivesAt: now.add(const Duration(hours: 13)),
              seatsAvailable: 9,
              operatorName: 'Trans Bony',
              otherOperator: true,
            ),
          ],
        ),
      );

      expect(find.text('Trans Bony'), findsOneWidget);
      expect(find.text('Autre compagnie'), findsOneWidget);
    });
  });

  group('what happened after the tap', () {
    Future<void> pump(WidgetTester tester, ChoiceAppliedDto applied) async {
      final catalog = await loadTestCatalog();
      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: TravelChosenScreen(applied: applied, onDone: () {}),
          ),
        ),
      );
    }

    testWidgets('a move states the new time, the new seat and the old ticket', (
      tester,
    ) async {
      await pump(
        tester,
        ChoiceAppliedDto(
          bookingRef: 'BEL-broken',
          kind: 'move',
          departureId: 'dep-later',
          departsAt: now.add(const Duration(hours: 8)),
          seatLabels: const ['22B'],
        ),
      );

      expect(find.text('Vous êtes replacé'), findsOneWidget);
      expect(find.textContaining('15:00'), findsOneWidget);
      expect(find.textContaining('22B'), findsOneWidget);
      // The old QR is still in their photo roll, and a conductor refusing it
      // at the door is our failure, not theirs.
      expect(find.textContaining("L'ancien ne permet plus"), findsOneWidget);
    });

    testWidgets('a refund carries the code that collects it', (tester) async {
      await pump(
        tester,
        const ChoiceAppliedDto(
          bookingRef: 'BEL-broken',
          kind: 'refund',
          refunded: Money.xaf(9300),
          claimCode: 'K7M2QRTV',
        ),
      );

      expect(find.text('Remboursement enregistré'), findsOneWidget);
      expect(find.textContaining('9 300'), findsOneWidget);
      // Spaced, like the agency payment code: this one is read aloud across
      // a counter too.
      expect(find.text('K 7 M 2 Q R T V'), findsOneWidget);
      expect(find.textContaining('par SMS'), findsOneWidget);
    });

    testWidgets('keeping says nothing changed, which is the point', (
      tester,
    ) async {
      await pump(
        tester,
        const ChoiceAppliedDto(bookingRef: 'BEL-broken', kind: 'keep'),
      );

      expect(find.text('Vous gardez votre place'), findsOneWidget);
      expect(find.textContaining('reste valable'), findsOneWidget);
    });
  });
}
