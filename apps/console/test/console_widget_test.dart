import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_console/src/application/console_workspace.dart';
import 'package:bel_console/src/application/ports/console_gateway.dart';
import 'package:bel_console/src/application/ports/file_picker.dart';
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
    required String preset,
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

  /// Kept as the encoded JSON rather than the draft, because what a test
  /// should assert about a drawn layout is what went on the wire — a draft
  /// object can be right while its encoding drops a field.
  Map<String, Object?>? drawn;

  @override
  Future<LayoutDto> drawLayout(LayoutDraft draft) async {
    drawn = draft.toJson();
    saved.add('draw:${draft.name}:${draft.capacity}');
    return LayoutDto(
      id: 'l-2',
      name: draft.name,
      version: 1,
      capacity: draft.capacity,
      mode: draft.mode.name,
      vehicleCount: 0,
    );
  }

  List<RefundPolicyDto> policyList = const [];
  bool hasDefault = false;

  /// The last policy written, kept as the domain object the screen produced —
  /// what a test should assert about a wizard is the *terms* it built, since
  /// the encoding is proven separately in `bel_contracts`.
  RefundPolicy? written;

  @override
  Future<({List<RefundPolicyDto> items, bool hasDefault})>
  refundPolicies() async => (items: policyList, hasDefault: hasDefault);

  @override
  Future<RefundPolicyDto> saveRefundPolicy({
    required String name,
    required RefundPolicy policy,
  }) async {
    written = policy;
    saved.add('policy:$name:${policy.tiers.length}');
    return RefundPolicyDto.fromDomain(policy, name: name, isDefault: false);
  }

  @override
  Future<RefundPolicyDto?> setDefaultRefundPolicy({
    String? policyId,
    int? version,
  }) async {
    saved.add('default:$policyId:$version');
    if (policyId == null) return null;
    return policyList.firstWhere(
      (p) => p.id == policyId && p.version == version,
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
  Future<SeatMapDto> seatMap(String departureId) => throw UnimplementedError();

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
  Future<VitrineDto> uploadVitrineAsset({
    required String asset,
    required List<int> bytes,
    required String mimeType,
  }) async {
    saved.add('upload:$asset:${bytes.length}:$mimeType');
    return vitrineRow = vitrineRow.withAssetUrls(
      logoUrl: 'https://storage.test/operators/op-1/logo.png',
    );
  }

  @override
  Future<VitrineDto> removeVitrineAsset(String asset) async {
    saved.add('remove:$asset');
    return vitrineRow = vitrineRow.withAssetUrls();
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
    passengers: const [PassengerDto(fullName: 'Aline M.', seatLabel: '1A')],
    tickets: const [(id: 't-1', seatLabel: '1A', qrPayload: 'payload')],
  );
}

void main() {
  late TranslationCatalog catalog;

  setUpAll(() async => catalog = await loadTestCatalog());

  Future<ConsoleWorkspace> pump(
    WidgetTester tester,
    _ScriptedConsole gateway, {
    FilePicker? files,
  }) async {
    // A realistic agency laptop rather than the 800x600 default. The console
    // is a desktop product and testing it at a phone's width would either
    // fail honestly or push the layout into shapes no operator will see.
    // The screens still do not overflow at 800px — that is a separate
    // property and the reason every header is Expanded rather than Spacer'd.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final workspace = ConsoleWorkspace(gateway: gateway, files: files);
    await tester.pumpWidget(ConsoleApp(catalog: catalog, workspace: workspace));
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
        _ScriptedConsole(capabilities: const ['booking.read', 'booking.sell']),
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
      await pump(
        tester,
        _ScriptedConsole(capabilities: const ['booking.read']),
      );

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
    final gateway =
        _ScriptedConsole(capabilities: const ['booking.read', 'fleet.manage'])
          ..vehicleList = const [
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

  group('the section builder', () {
    /// Opens Fleet and taps "Dessiner un plan". Every test here starts the
    /// same way, and the setup is longer than the assertion in most of them.
    /// The `TextField` inside a `KField` with this label.
    ///
    /// `KField` renders its label as a sibling of the input rather than as an
    /// `InputDecoration`, so `widgetWithText(TextField, …)` finds nothing.
    Finder fieldNamed(String label) => find.descendant(
      of: find.widgetWithText(KField, label),
      matching: find.byType(TextField),
    );

    Future<ConsoleWorkspace> openBuilder(
      WidgetTester tester,
      _ScriptedConsole gateway,
    ) async {
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.fleet);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dessiner un plan'));
      await tester.pumpAndSettle();
      return workspace;
    }

    testWidgets('a coach is drawn, and the preview is the real seat map', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'fleet.manage'],
      );
      await openBuilder(tester, gateway);

      // The default section is ten rows of 2+2. The preview is KSeatMap —
      // the widget that sells the seat — so an operator sees the traveller's
      // screen rather than a drawing of one.
      expect(find.byType(KSeatMap), findsOneWidget);
      expect(find.text('40 places'), findsOneWidget);
      // Labels come from the domain, and I is skipped because a capital I
      // reads as a 1 on a seat sticker.
      expect(find.text('1A'), findsOneWidget);
      expect(find.text('10D'), findsOneWidget);
    });

    testWidgets('a typo empties the preview instead of crashing it', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'fleet.manage'],
      );
      await openBuilder(tester, gateway);

      // `9+9` is eighteen seats across, which used to walk off the end of the
      // letter table with a RangeError. The section simply stops being
      // drawable, and says so.
      await tester.enterText(fieldNamed('Sièges de front'), '9+9');
      await tester.pumpAndSettle();

      expect(find.byType(KSeatMap), findsNothing);
      expect(find.text('Aucune place pour l\'instant.'), findsOneWidget);
      expect(find.textContaining('ne peut pas être dessinée'), findsOneWidget);
    });

    testWidgets('a nameless layout cannot be saved', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'fleet.manage'],
      );
      await openBuilder(tester, gateway);

      // The default sections are workable; only the name is missing. A
      // disabled save with no explanation is the most common way software
      // strands somebody, so the hint is asserted too.
      final save = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Enregistrer'),
      );
      expect(save.onPressed, isNull);
      expect(find.textContaining('Complétez le nom'), findsOneWidget);
      expect(gateway.drawn, isNull);
    });

    testWidgets('a second section starts where the first one ends', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'fleet.manage'],
      );
      await openBuilder(tester, gateway);

      await tester.enterText(fieldNamed('Nom du plan'), 'Car 51');
      // Below the fold on a 1280×800 laptop once the first section is drawn.
      await tester.ensureVisible(find.text('Ajouter une section'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter une section'));
      await tester.pumpAndSettle();

      // The 5-across rear bench every generic tool forgets: one row, five
      // seats, starting at 11 because the section above it ends at 10. The
      // operator never counts.
      await tester.enterText(fieldNamed('Sièges de front').last, '5');
      await tester.enterText(fieldNamed('Rangées').last, '1');
      await tester.pumpAndSettle();

      expect(find.text('Commence à la rangée 11'), findsOneWidget);
      expect(find.text('45 places'), findsOneWidget);

      await tester.tap(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.pumpAndSettle();

      // What went on the wire, not what the draft held: a draft can be right
      // while its encoding drops a field.
      final sent = gateway.drawn!;
      expect(sent['name'], 'Car 51');
      expect(sent['mode'], 'bus');
      final sections = sent['sections']! as List;
      expect(sections, hasLength(2));
      expect((sections[1] as Map)['abreast'], '5');
      expect((sections[1] as Map)['startRow'], 11);
      expect(gateway.saved, contains('draw:Car 51:45'));
      // Back on the fleet screen, with the layout named.
      expect(find.textContaining('Car 51'), findsWidgets);
    });

    testWidgets('a VIP section is priced, and only one way', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'fleet.manage'],
      );
      await openBuilder(tester, gateway);

      await tester.enterText(fieldNamed('Nom du plan'), 'VIP avant');
      await tester.tap(find.text('Prix de base'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Multiplié').last);
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Multiplicateur'), '1,5');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.pumpAndSettle();

      final section = (gateway.drawn!['sections']! as List).first as Map;
      // A comma is what a French keyboard produces and what an operator will
      // type. It is a decimal point here or it is a fare of nothing.
      expect(section['fareMultiplier'], 1.5);
      // Never both. The server refuses a section priced two ways, and the
      // encoder is what guarantees the console never sends one.
      expect(section.containsKey('fareSupplement'), isFalse);
    });

    testWidgets('a cancelled draw sends nothing', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'fleet.manage'],
      );
      await openBuilder(tester, gateway);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(gateway.drawn, isNull);
      expect(find.text('Plans de salle'), findsOneWidget);
    });
  });

  group('refund terms', () {
    Finder fieldNamed(String label) => find.descendant(
      of: find.widgetWithText(KField, label),
      matching: find.byType(TextField),
    );

    /// The standard preset as a stored row: 90% at 48 h, 50% at 24 h.
    RefundPolicyDto stored(
      String name, {
      int version = 1,
      bool isDefault = false,
      int bookingCount = 0,
    }) {
      final base = RefundPolicyDto.fromDomain(
        RefundPolicy.standard(),
        name: name,
        isDefault: isDefault,
        bookingCount: bookingCount,
      );
      return RefundPolicyDto(
        id: 'p-$name',
        version: version,
        name: name,
        tiers: base.tiers,
        destination: base.destination,
        processingHours: base.processingHours,
        refundServiceFee: base.refundServiceFee,
        nonRefundableFares: base.nonRefundableFares,
        isDefault: isDefault,
        bookingCount: bookingCount,
      );
    }

    Future<ConsoleWorkspace> openPolicies(
      WidgetTester tester,
      _ScriptedConsole gateway,
    ) async {
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.policies);
      await tester.pumpAndSettle();
      return workspace;
    }

    testWidgets('no terms at all is stated, not left blank', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      // "No terms" is not a neutral default — it is a decision with a
      // consequence, and a screen that says nothing is a screen that hides it.
      expect(
        find.text("Aucune condition n'est appliquée aux nouvelles ventes."),
        findsOneWidget,
      );
      expect(find.textContaining('libre-service'), findsOneWidget);
    });

    testWidgets('a stored policy is shown as sentences, never as numbers', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      )..policyList = [stored('Standard', isDefault: true, bookingCount: 42)];
      await openPolicies(tester, gateway);

      // Rendered by RefundPolicy.describe() — the same object the server
      // executes, so the console and the traveller cannot read different
      // terms from one policy.
      expect(
        find.textContaining('48 h avant le départ : 90 % remboursés'),
        findsOneWidget,
      );
      // The band a tier table never states, and the one travellers hit.
      expect(
        find.textContaining('Moins de 24 h avant le départ'),
        findsOneWidget,
      );
      // The floor an operator cannot configure away.
      expect(
        find.textContaining('vous êtes remboursé intégralement'),
        findsWidgets,
      );
      // The honest answer to "can I just change this?".
      expect(find.textContaining('42 réservation(s)'), findsOneWidget);
    });

    testWidgets('the wizard writes terms, and warns before it saves', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();

      // Rule 2 of ADR-0015: the console says a save creates a version, before
      // the button rather than in an apology afterwards.
      expect(find.textContaining('crée une nouvelle version'), findsOneWidget);

      // Nameless, so the button refuses and says what it wants.
      final disabled = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Enregistrer'),
      );
      expect(disabled.onPressed, isNull);

      await tester.enterText(fieldNamed('Nom de ces conditions'), 'Maison');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.pumpAndSettle();

      // The preset it opened on: 90% at 48 h, 50% at 24 h.
      expect(gateway.written!.tiers, hasLength(2));
      expect(gateway.written!.tiers.first.rateBps, 9000);
      expect(gateway.written!.tiers.last.rateBps, 5000);
      expect(gateway.saved, contains('policy:Maison:2'));
    });

    testWidgets('bands in the wrong order cannot be saved', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();
      await tester.enterText(
        fieldNamed('Nom de ces conditions'),
        'À l\'envers',
      );

      // Swap the first band's lead time below the second's. Every field is
      // individually valid; the set is not — and tiers are matched in order,
      // so this policy would answer every request with its most generous
      // band and nobody would notice until the month was counted.
      await tester.enterText(
        fieldNamed('Au moins (heures avant le départ)').first,
        '2',
      );
      await tester.pumpAndSettle();

      final save = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Enregistrer'),
      );
      expect(save.onPressed, isNull);
      expect(find.textContaining('du plus tôt au plus tard'), findsWidgets);
      expect(gateway.written, isNull);
    });

    testWidgets('the preview changes with the answer, before anything saves', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Remboursement effectué sous 72 h'),
        findsOneWidget,
      );

      await tester.tap(find.text('Souple — 100 % jusqu\'à 24 h avant'));
      await tester.pumpAndSettle();

      // The preset's own words, generated rather than typed.
      expect(
        find.textContaining(
          "Jusqu'à 24 h avant le départ : remboursement intégral",
        ),
        findsOneWidget,
      );
      expect(gateway.written, isNull);
    });

    testWidgets('cash at the agency drops the promise it cannot keep', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();
      // Below the fold on a 1280×800 laptop: the questions run past the
      // viewport once the preset's two bands are drawn.
      await tester.ensureVisible(
        find.text('Sur le moyen de paiement d\'origine'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sur le moyen de paiement d\'origine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("En espèces, à l'agence").last);
      await tester.pumpAndSettle();

      // "Within 72 hours" would be a promise about somebody's opening times,
      // so both the question and the sentence disappear.
      expect(find.text('Délai de traitement (heures)'), findsNothing);
      expect(find.textContaining('Remboursement effectué sous'), findsNothing);
      expect(
        find.textContaining("Remboursé en espèces, à l'agence"),
        findsOneWidget,
      );
    });

    testWidgets('a vendor may read the terms and not rewrite them', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(capabilities: const ['booking.read'])
        ..policyList = [stored('Standard', isDefault: true)];
      await openPolicies(tester, gateway);

      // A vendor at the counter is asked "can I get my money back?" far more
      // often than an owner is, so the tab is theirs — the editing is not.
      expect(find.text('Conditions'), findsWidgets);
      expect(find.text('Écrire des conditions'), findsNothing);
      expect(find.text('Appliquer aux nouvelles ventes'), findsNothing);
      expect(find.textContaining('90 % remboursés'), findsOneWidget);
    });
  });

  group('the vitrine', () {
    testWidgets('with nowhere to pick a file, no upload button is offered', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'vitrine.manage'],
      );
      final workspace = await pump(tester, gateway);

      workspace.openSection(ConsoleSection.vitrine);
      await tester.pumpAndSettle();

      // A button that cannot open a dialog is worse than a sentence saying
      // what the default is.
      expect(find.text('Téléverser'), findsNothing);
      expect(find.byType(KMonogram), findsWidgets);
    });

    testWidgets('a chosen file is sent, and the preview shows it', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'vitrine.manage'],
      );
      final picker = _ScriptedPicker(
        const PickedFile(
          name: 'logo.png',
          bytes: [1, 2, 3, 4],
          mimeType: 'image/png',
        ),
      );
      final workspace = await pump(tester, gateway, files: picker);

      workspace.openSection(ConsoleSection.vitrine);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Téléverser'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('upload:logo:4:image/png'));
      // Only the formats the server will actually accept are offered, so the
      // dialog does not let somebody choose a GIF and then refuse it.
      expect(picker.accepted, contains('image/svg+xml'));
      expect(picker.accepted, isNot(contains('image/gif')));

      // The mark replaces the monogram in the preview, from the response
      // rather than from a URL the client built.
      expect(find.byType(Image), findsWidgets);
    });

    // Opening a file dialog and closing it again is the common outcome, and a
    // screen that showed a failure for it would be wrong more often than
    // right.
    testWidgets('a dismissed dialog sends nothing and shows no error', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'vitrine.manage'],
      );
      final workspace = await pump(
        tester,
        gateway,
        files: _ScriptedPicker(null),
      );

      workspace.openSection(ConsoleSection.vitrine);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Téléverser'));
      await tester.pumpAndSettle();

      expect(gateway.saved, isEmpty);
      expect(workspace.failure, isNull);
      expect(workspace.busy, isFalse);
    });

    testWidgets('removing it puts the monogram back', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'vitrine.manage'],
      );
      final workspace = await pump(
        tester,
        gateway,
        files: _ScriptedPicker(
          const PickedFile(
            name: 'logo.png',
            bytes: [1, 2, 3, 4],
            mimeType: 'image/png',
          ),
        ),
      );

      workspace.openSection(ConsoleSection.vitrine);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Téléverser'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Retirer le logo'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('remove:logo'));
      expect(find.byType(KMonogram), findsWidgets);
    });

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

/// A file dialog that has already decided.
final class _ScriptedPicker implements FilePicker {
  _ScriptedPicker(this._file);

  final PickedFile? _file;
  List<String> accepted = const [];

  @override
  Future<PickedFile?> pick({List<String> accept = const []}) async {
    accepted = accept;
    return _file;
  }
}
