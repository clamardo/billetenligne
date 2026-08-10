import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_console/src/application/console_workspace.dart';
import 'package:bel_console/src/application/ports/console_gateway.dart';
import 'package:bel_console/src/presentation/app.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// A gateway the test drives directly.
///
/// Scripted rather than a demo twin, unlike the traveller app's: there is no
/// demo console (`main.dart` says why — a fake one would be a second
/// definition of every coach and route), so the only fake that should exist
/// is one a test controls completely.
final class _ScriptedConsole implements ConsoleGateway {
  _ScriptedConsole({required this.capabilities});

  List<String> capabilities;
  ApiFailure? identityFailure;

  List<LayoutDto> layoutList = const [];
  List<VehicleDto> vehicleList = const [];
  List<DepartureBoardDto> boardList = const [];

  final saved = <String>[];
  MaterialisationDto materialiseResult = const MaterialisationDto(
    created: 3,
    alreadyExisted: 0,
    skipped: [],
  );

  @override
  Future<ConsoleIdentityDto> identity() async {
    if (identityFailure != null) throw identityFailure!;
    return ConsoleIdentityDto(
      userId: 'u-1',
      operatorId: 'op-1',
      roles: const ['org_admin'],
      capabilities: capabilities,
      stationIds: const ['st-bzv'],
    );
  }

  @override
  Future<List<LayoutDto>> layouts() async => layoutList;

  @override
  Future<LayoutDto> saveLayout({
    required String name,
    String? preset,
    int? rows,
  }) async {
    saved.add('layout:$name:$preset:$rows');
    return LayoutDto(
      id: 'l-1',
      name: name,
      version: 1,
      capacity: 49,
      mode: 'bus',
      vehicleCount: 0,
    );
  }

  @override
  Future<List<VehicleDto>> vehicles() async => vehicleList;

  @override
  Future<VehicleDto> saveVehicle({
    required String registration,
    required String layoutId,
    String? nickname,
    String? model,
  }) async {
    saved.add('vehicle:$registration:$layoutId');
    return VehicleDto(
      id: 'v-1',
      registration: registration,
      layoutId: layoutId,
      layoutName: 'Coach',
      capacity: 49,
      status: 'active',
      sellable: true,
    );
  }

  @override
  Future<List<String>> setVehicleStatus({
    required String vehicleId,
    required String status,
  }) async {
    saved.add('status:$vehicleId:$status');
    return status == 'active' ? const [] : const ['dep-1', 'dep-2'];
  }

  @override
  Future<List<RouteDto>> routes() async => const [];

  @override
  Future<RouteDto> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
  }) async {
    saved.add('route:$code');
    return RouteDto(
      id: 'r-1',
      code: code,
      originCity: originCity,
      destinationCity: destinationCity,
      durationMinutes: durationMinutes,
      active: true,
    );
  }

  @override
  Future<List<CityDto>> cities() async => const [
    CityDto(code: 'BZV', name: 'Brazzaville'),
    CityDto(code: 'PNR', name: 'Pointe-Noire'),
  ];

  @override
  Future<List<ScheduleDto>> schedules() async => const [];

  @override
  Future<ScheduleDto> saveSchedule({
    required String routeId,
    required String rrule,
    required String departureTime,
    required int fareMinor,
    required DateTime validFrom,
    String? vehicleId,
    DateTime? validUntil,
  }) async {
    saved.add('schedule:$rrule:$departureTime');
    return ScheduleDto(
      id: 's-1',
      routeId: routeId,
      routeCode: 'BZV-PNR',
      rrule: rrule,
      departureTime: departureTime,
      fare: Money(fareMinor, Currency.xaf),
      validFrom: validFrom,
      active: true,
    );
  }

  @override
  Future<MaterialisationDto> materialise({
    required String scheduleId,
    required DateTime from,
    required DateTime to,
  }) async => materialiseResult;

  @override
  Future<List<DepartureBoardDto>> board(DateTime localDate) async => boardList;

  @override
  Future<ManifestDto> manifest(String departureId) async => ManifestDto(
    departureId: departureId,
    routeCode: 'BZV-PNR',
    departsAt: DateTime.utc(2026, 8, 10, 5),
    capacity: 49,
    sold: 1,
    boarded: 0,
    passengers: const [
      ManifestPassengerDto(
        seatLabel: '1A',
        passengerName: 'Aline M.',
        bookingRef: 'BEL-7QK4M2',
        boarded: false,
      ),
    ],
  );

  @override
  Future<SeatMapDto> seatMap(String departureId) =>
      throw UnimplementedError();

  @override
  Future<CounterSaleDto> collect({
    required String paymentCode,
    required String stationId,
  }) async {
    saved.add('collect:$paymentCode:$stationId');
    return _sale;
  }

  VitrineDto vitrineRow = const VitrineDto(
    operatorId: 'op-1',
    code: 'ODN',
    legalName: 'Ocean du Nord SARL',
    tradingName: 'Ocean du Nord',
    accentHue: 'foret',
    headerPattern: 'flat',
  );

  @override
  Future<VitrineDto> vitrine() async => vitrineRow;

  @override
  Future<VitrineDto> saveVitrine(SaveVitrineRequest request) async {
    saved.add(
      'vitrine:${request.accentHue}:${request.headerPattern}:'
      '${request.titleFr}:${request.taglineFr}',
    );
    return vitrineRow = VitrineDto(
      operatorId: vitrineRow.operatorId,
      code: vitrineRow.code,
      legalName: vitrineRow.legalName,
      tradingName: vitrineRow.tradingName,
      accentHue: request.accentHue,
      headerPattern: request.headerPattern,
      titleFr: request.titleFr,
      titleEn: request.titleEn,
      taglineFr: request.taglineFr,
      taglineEn: request.taglineEn,
    );
  }

  @override
  Future<CounterSaleDto> sell({
    required String departureId,
    required String buyerPhone,
    required List<PassengerDto> passengers,
    required String stationId,
    required String idempotencyKey,
  }) async {
    saved.add('sell:$departureId:$buyerPhone');
    return _sale;
  }

  static final _sale = CounterSaleDto(
    id: 'bk-1',
    ref: 'BEL-7QK4M2',
    state: 'confirmed',
    total: const Money.xaf(12300),
    fare: const Money.xaf(12000),
    serviceFee: const Money.xaf(300),
    passengers: const [
      PassengerDto(fullName: 'Aline M.', seatLabel: '1A'),
    ],
    tickets: const [
      (id: 't-1', seatLabel: '1A', qrPayload: 'payload'),
    ],
  );
}

void main() {
  late TranslationCatalog catalog;

  setUpAll(() async => catalog = await loadTestCatalog());

  Future<ConsoleWorkspace> pump(
    WidgetTester tester,
    _ScriptedConsole gateway,
  ) async {
    // A realistic agency laptop rather than the 800x600 default. The console
    // is a desktop product and testing it at a phone's width would either
    // fail honestly or push the layout into shapes no operator will see.
    // The screens still do not overflow at 800px — that is a separate
    // property and the reason every header is Expanded rather than Spacer'd.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final workspace = ConsoleWorkspace(gateway: gateway);
    await tester.pumpWidget(
      ConsoleApp(catalog: catalog, workspace: workspace),
    );
    await tester.pumpAndSettle();
    return workspace;
  }

  group('the rail is built from capabilities', () {
    testWidgets('an owner sees every section', (tester) async {
      await pump(
        tester,
        _ScriptedConsole(
          capabilities: const [
            'booking.read',
            'booking.sell',
            'fleet.manage',
            'route.manage',
            'departure.manage',
          ],
        ),
      );

      for (final label in const [
        "Aujourd'hui",
        'Guichet',
        'Flotte',
        'Lignes',
        'Horaires',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('a vendor has no Fleet tab at all', (tester) async {
      await pump(
        tester,
        _ScriptedConsole(
          capabilities: const ['booking.read', 'booking.sell'],
        ),
      );

      // Not a greyed one, which invites a support call, and not a visible one
      // that 403s, which teaches people our buttons lie (ADR-0011).
      expect(find.text('Guichet'), findsOneWidget);
      expect(find.text('Flotte'), findsNothing);
      expect(find.text('Horaires'), findsNothing);
    });

    testWidgets('a failure to load identity is a retry, not a blank app', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(capabilities: const [])
        ..identityFailure = const NetworkUnreachable();
      await pump(tester, gateway);

      // The console renders nothing until it knows the capabilities, so this
      // is the one screen that must never be empty.
      expect(find.textContaining('Réessayer'), findsWidgets);
    });
  });

  group("the dispatcher's day", () {
    testWidgets('separates held from sold', (tester) async {
      final gateway = _ScriptedConsole(capabilities: const ['booking.read'])
        ..boardList = [
          DepartureBoardDto(
            id: 'dep-1',
            routeCode: 'BZV-PNR',
            departsAt: DateTime.utc(2026, 8, 10, 5),
            status: 'scheduled',
            capacity: 49,
            sold: 20,
            held: 28,
            available: 1,
            vehicle: 'ODN-001',
          ),
        ];

      await pump(tester, gateway);

      // "48 of 49 sold" and "20 sold, 28 held" are completely different
      // situations twenty minutes before departure.
      expect(find.text('20'), findsOneWidget);
      expect(find.text('28'), findsOneWidget);
      expect(find.text('ODN-001'), findsOneWidget);
    });

    testWidgets('a departure with no coach says so, loudly', (tester) async {
      final gateway = _ScriptedConsole(capabilities: const ['booking.read'])
        ..boardList = [
          DepartureBoardDto(
            id: 'dep-1',
            routeCode: 'BZV-PNR',
            departsAt: DateTime.utc(2026, 8, 10, 5),
            status: 'scheduled',
            capacity: 49,
            sold: 0,
            held: 0,
            available: 49,
          ),
        ];

      await pump(tester, gateway);
      expect(find.text('Aucun car affecté'), findsOneWidget);
    });

    testWidgets('an empty day names the cause', (tester) async {
      await pump(tester, _ScriptedConsole(capabilities: const ['booking.read']));

      // On a day with no departures the answer is almost always "the
      // timetable was never published", and that is two clicks away.
      expect(find.textContaining('Publiez un horaire'), findsOneWidget);
    });

    testWidgets('the manifest opens and lists confirmed passengers', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(capabilities: const ['booking.read'])
        ..boardList = [
          DepartureBoardDto(
            id: 'dep-1',
            routeCode: 'BZV-PNR',
            departsAt: DateTime.utc(2026, 8, 10, 5),
            status: 'scheduled',
            capacity: 49,
            sold: 1,
            held: 0,
            available: 48,
          ),
        ];

      await pump(tester, gateway);
      await tester.tap(find.text('Liste'));
      await tester.pumpAndSettle();

      expect(find.text('Aline M.'), findsOneWidget);
      expect(find.text('BEL-7QK4M2'), findsOneWidget);
    });
  });

  group('the guichet', () {
    testWidgets('collects a payment code and shows a receipt', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'booking.sell'],
      );
      await pump(tester, gateway);

      await tester.tap(find.text('Guichet'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'K4M2Q');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Encaisser').last);
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('collect:K4M2Q:st-bzv'));
      // The only confirmation either party gets at the counter — the SMS goes
      // through the outbox and may take a minute.
      expect(find.text('Paiement encaissé'), findsOneWidget);
      expect(find.text('BEL-7QK4M2'), findsOneWidget);
    });

    testWidgets('a short code cannot be submitted', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'booking.sell'],
      );
      await pump(tester, gateway);
      await tester.tap(find.text('Guichet'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'K4M');
      await tester.pumpAndSettle();

      expect(find.text('Le code fait cinq caractères'), findsOneWidget);
      expect(gateway.saved, isEmpty);
    });
  });

  testWidgets('taking a coach off the road says what it was carrying', (
    tester,
  ) async {
    final gateway = _ScriptedConsole(
      capabilities: const ['booking.read', 'fleet.manage'],
    )..vehicleList = const [
      VehicleDto(
        id: 'v-1',
        registration: 'ODN-001',
        layoutId: 'l-1',
        layoutName: 'Coach 2+2',
        capacity: 49,
        status: 'active',
        sellable: true,
      ),
    ];

    await pump(tester, gateway);
    await tester.tap(find.text('Flotte'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atelier').last);
    await tester.pumpAndSettle();

    // Never a bare success: those departures now have no coach, and somebody
    // has to reassign one before the passengers arrive.
    expect(gateway.saved, contains('status:v-1:maintenance'));
    expect(find.textContaining("n'ont plus de car"), findsOneWidget);
  });

  group('the vitrine', () {
    testWidgets('the closed sets are the ones the server refuses by', (
      tester,
    ) async {
      // The design system paints the hues and the contract lists them,
      // because the server cannot import Flutter. Two lists is the price of
      // that; this is what stops them drifting apart.
      expect(AccentHue.values.map((h) => h.name).toList(), Vitrine.accents);
      expect(
        HeaderPattern.values.map((p) => p.name).toList(),
        Vitrine.patterns,
      );
    });

    testWidgets('the preview is drawn from the form, before anything saves', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'vitrine.manage'],
      );
      final workspace = await pump(tester, gateway);

      workspace.openSection(ConsoleSection.vitrine);
      await tester.pumpAndSettle();

      // The default: no title, so the trading name carries the header, and a
      // generated monogram carries the mark.
      expect(find.text('Ocean du Nord'), findsWidgets);
      expect(find.byType(KMonogram), findsWidgets);

      await tester.enterText(find.byType(TextField).first, 'Ocean Express');
      await tester.pumpAndSettle();

      // Rendered by the same widget the public page uses, and rendered
      // before the save — which is the whole point of the screen.
      expect(find.text('Ocean Express'), findsWidgets);
      expect(gateway.saved, isEmpty);
    });

    testWidgets('an accent is chosen from eight, and sent by name', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'vitrine.manage'],
      );
      final workspace = await pump(tester, gateway);

      workspace.openSection(ConsoleSection.vitrine);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Indigo'));
      await tester.pumpAndSettle();

      // The form is taller than a laptop viewport, so the save button lives
      // below the fold on a 1280x800 screen — which is the screen an agency
      // actually has.
      await tester.ensureVisible(find.text('Enregistrer la vitrine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer la vitrine'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('vitrine:indigo:flat::'));
    });

    testWidgets('a vendor gets no vitrine tab, and no editor', (tester) async {
      await pump(
        tester,
        _ScriptedConsole(capabilities: const ['booking.read', 'booking.sell']),
      );

      expect(find.text('Vitrine'), findsNothing);
    });
  });
}
