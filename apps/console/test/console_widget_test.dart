import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_console/src/application/console_workspace.dart';
import 'package:bel_console/src/application/ports/console_gateway.dart';
import 'package:bel_console/src/application/ports/file_picker.dart';
import 'package:bel_console/src/application/ports/file_saver.dart';
import 'package:bel_console/src/application/ports/onboarding_gateway.dart';
import 'package:bel_console/src/application/onboarding_workspace.dart';
import 'package:bel_console/src/presentation/app.dart';
import 'package:bel_console/src/presentation/l10n.dart';
import 'package:bel_console/src/presentation/screens/onboarding_screen.dart';
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

  RefundOfferDto? offerResult;
  IssuedRefundDto? issuedResult;

  @override
  Future<RefundOfferDto> refundOffer(String bookingRef) async {
    saved.add('quote:$bookingRef');
    return offerResult ??
        RefundOfferDto(
          bookingRef: bookingRef,
          state: 'confirmed',
          departsAt: DateTime.utc(2028, 3, 6),
          fare: const Money.xaf(9000),
          serviceFee: const Money.xaf(300),
        );
  }

  @override
  Future<IssuedRefundDto> refundBooking({
    required String bookingRef,
    required String reason,
  }) async {
    saved.add('refund:$bookingRef:$reason');
    return issuedResult ??
        IssuedRefundDto(
          id: 'r-1',
          bookingRef: bookingRef,
          amount: const Money.xaf(8100),
          destination: 'agencyCash',
          state: 'claim_issued',
          claimCode: 'K4M2QX',
          claimExpiresAt: DateTime.utc(2028, 6, 1),
        );
  }

  @override
  Future<ClaimedRefundDto> claimRefund({
    required String claimCode,
    required String stationId,
  }) async {
    saved.add('claim:$claimCode:$stationId');
    return ClaimedRefundDto(
      id: 'r-1',
      bookingRef: 'BEL-K4M2QX',
      amount: const Money.xaf(8100),
      stationId: stationId,
    );
  }

  List<RefundPolicyDto> policyList = const [];
  bool hasDefault = false;

  /// The last policy written, kept as the domain object the screen produced —
  /// what a test should assert about a wizard is the *terms* it built, since
  /// the encoding is proven separately in `bel_contracts`.
  RefundPolicy? written;

  /// And the change terms beside them, for the same reason.
  ChangePolicy? writtenChange;
  MissedPolicy? writtenMissed;
  MissedOptionsDto? missedResult;

  @override
  Future<({List<RefundPolicyDto> items, bool hasDefault})>
  refundPolicies() async => (items: policyList, hasDefault: hasDefault);

  @override
  Future<RefundPolicyDto> saveRefundPolicy({
    required String name,
    required RefundPolicy policy,
    ChangePolicy change = ChangePolicy.standard,
    MissedPolicy missed = MissedPolicy.notOffered,
  }) async {
    written = policy;
    writtenChange = change;
    writtenMissed = missed;
    saved.add('policy:$name:${policy.tiers.length}');
    return RefundPolicyDto.fromDomain(
      policy,
      name: name,
      isDefault: false,
      change: change,
      missed: missed,
    );
  }

  @override
  Future<MissedOptionsDto> missedOptions(String bookingRef) async {
    saved.add('missedOptions:$bookingRef');
    return missedResult ??
        MissedOptionsDto(
          bookingRef: bookingRef,
          originCity: 'BZV',
          destinationCity: 'PNR',
          seatsNeeded: 1,
          departedAt: DateTime.utc(2026, 8, 10, 5),
          paidFare: const Money.xaf(12000),
          options: const [],
        );
  }

  @override
  Future<MissedTransferDto> moveMissed({
    required String bookingRef,
    required String departureId,
    String? stationId,
  }) async {
    saved.add('missedMove:$bookingRef:$departureId:$stationId');
    return MissedTransferDto(
      bookingRef: bookingRef,
      departureId: departureId,
      departsAt: DateTime.utc(2026, 8, 10, 8, 30),
      seatLabels: const ['4C'],
      paid: const Money.xaf(2700),
      stationName: 'Gare de Kinsoundi',
    );
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

  /// The lines this operator runs. The agreement dialog offers corridors
  /// built from these rather than a free-text field, so nobody agrees to
  /// protect a road neither company serves.
  List<RouteDto> routeList = const [];
  List<StationDto> stationList = const [];

  @override
  Future<List<RouteDto>> routes() async => routeList;

  /// The stops of the last road saved, so a test can assert what the form
  /// actually sent rather than what it drew.
  List<RouteStopDto>? savedStops;

  @override
  @override
  Future<RouteDto> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    List<RouteStopDto>? stops,
  }) async {
    saved.add('route:$code');
    savedStops = stops;
    return RouteDto(
      id: id ?? 'r-1',
      code: code,
      originCity: originCity,
      destinationCity: destinationCity,
      durationMinutes: durationMinutes,
      active: true,
      stops: stops ?? const [],
    );
  }

  @override
  Future<List<CityDto>> cities() async => const [
    CityDto(code: 'BZV', name: 'Brazzaville'),
    CityDto(code: 'PNR', name: 'Pointe-Noire'),
  ];

  @override
  Future<List<StationDto>> stations() async => stationList;

  @override
  Future<StationDto> saveStation({
    required String cityCode,
    required String name,
    String? id,
    String? boardingNotes,
    bool active = true,
  }) async {
    saved.add('station:$cityCode:$name:$active');
    final station = StationDto(
      id: id ?? 'st-new',
      cityCode: cityCode,
      name: name,
      boardingNotes: boardingNotes,
      active: active,
    );
    stationList = [...stationList.where((s) => s.id != station.id), station];
    return station;
  }

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

  /// What the last declaration was answered with, and how many it reached.
  int declaredAffected = 42;
  bool declaredFree = true;

  @override
  Future<DeclaredDisruptionDto> declareDisruption({
    required String departureId,
    required DeclareDisruptionRequest request,
  }) async {
    saved.add(
      'disruption:$departureId:${request.kind.name}:${request.cause.name}'
      ':${request.note ?? ''}',
    );
    return DeclaredDisruptionDto(
      disruption: DisruptionDto(
        id: 'd-1',
        kind: request.kind,
        cause: request.cause,
        declaredAt: DateTime.utc(2026, 8, 10, 5, 40),
        marksInvoluntary: declaredFree,
        note: request.note,
        revisedDepartsAt: request.revisedDepartsAt,
      ),
      departureId: departureId,
      bookingsAffected: declaredAffected,
      departureStatus: 'cancelled',
    );
  }

  /// This operator's statements, as the server would answer.
  List<PayoutRunDto> statementList = const [];

  /// The standing agreements, as the server would answer.
  List<ProtectionAgreementDto> agreementList = const [];

  @override
  Future<List<ProtectionAgreementDto>> protectionAgreements() async {
    saved.add('protection');
    return agreementList;
  }

  @override
  Future<ProtectionAgreementDto> proposeAgreement(
    ProposeAgreementRequest request,
  ) async {
    saved.add(
      'propose:${request.counterpartyCode}:${request.corridors.join(",")}'
      ':${request.rebillDiscountBps}',
    );
    return _agreement(
      id: 'agr-new',
      state: 'proposed',
      weProposed: true,
      corridors: request.corridors,
      discountBps: request.rebillDiscountBps,
      cap: request.monthlyCapSeats,
    );
  }

  @override
  Future<ProtectionAgreementDto> decideAgreement({
    required String agreementId,
    required AgreementDecisionRequest request,
  }) async {
    saved.add('decide:$agreementId:${request.decision}');
    return _agreement(
      id: agreementId,
      state: switch (request.decision) {
        'accept' || 'resume' => 'active',
        'suspend' => 'suspended',
        _ => 'ended',
      },
      weProposed: false,
    );
  }

  @override
  Future<List<PayoutRunDto>> statements() async {
    saved.add('statements');
    return statementList;
  }

  /// What the download returns. Bytes and a name, the way the server sends
  /// them — the client never composes the name of a commercial document.
  var pdfBytes = const <int>[0x25, 0x50, 0x44, 0x46];
  var pdfFilename = 'releve-ocean-du-nord-2026-08-01.pdf';

  @override
  Future<({List<int> bytes, String filename, String mimeType})> statementPdf(
    String runId,
  ) async {
    saved.add('statementPdf:$runId');
    return (
      bytes: pdfBytes,
      filename: pdfFilename,
      mimeType: 'application/pdf',
    );
  }

  /// The live requests, as the server would answer.
  List<ProtectionRequestDto> requestList = const [];

  /// Everybody's departures on a road, as the public search would answer.
  List<DepartureSummaryDto> tripList = const [];

  /// How many of the party the receiving coach could actually take. Set per
  /// test: "everybody" and "1 of 2" are different sentences on the console,
  /// and only one of them sends somebody looking for another coach.
  int? movedSeats;

  @override
  Future<List<ProtectionRequestDto>> protectionRequests() async {
    saved.add('requests');
    return requestList;
  }

  @override
  Future<ProtectionRequestDto> askForProtection(
    ProtectionRequestBody request,
  ) async {
    saved.add(
      'ask:${request.departureId}:${request.replacementDepartureId}'
      ':${request.note ?? ''}',
    );
    return _request(id: 'req-new');
  }

  @override
  Future<ProtectionRequestDto> decideProtectionRequest({
    required String requestId,
    required AgreementDecisionRequest request,
  }) async {
    saved.add('decideRequest:$requestId:${request.decision}');
    // Answered from the row the console is showing, so "how many were asked
    // for" survives the round trip — the difference between "everybody" and
    // "2 of 5" is the whole point of the notice.
    final asked = requestList
        .where((r) => r.id == requestId)
        .firstOrNull
        ?.seatsRequested;
    return _request(
      id: requestId,
      state: request.decision == 'accept' ? 'applied' : 'declined',
      seatsRequested: asked ?? 2,
      seatsMoved: request.decision == 'accept'
          ? movedSeats ?? asked ?? 2
          : null,
      declineReason: request.reason,
    );
  }

  @override
  Future<List<DepartureSummaryDto>> tripsOn({
    required String originCity,
    required String destinationCity,
    required DateTime date,
  }) async {
    saved.add('trips:$originCity:$destinationCity');
    return tripList;
  }

  /// How many of the moved party the replacement could take. Set per test:
  /// the console renders "everybody" and "18 of 42" differently, and only one
  /// of those tells a dispatcher what to do next.
  int rebookLeft = 0;

  @override
  Future<RebookingAppliedDto> rebookOnto({
    required String departureId,
    required RebookRequest request,
  }) async {
    saved.add(
      'rebook:$departureId:${request.replacementDepartureId}'
      ':${request.note ?? ''}',
    );
    return RebookingAppliedDto(
      departureId: departureId,
      replacementDepartureId: request.replacementDepartureId,
      replacementDepartsAt: DateTime.utc(2026, 8, 10, 13),
      moved: const [
        RebookedPartyDto(
          bookingId: 'b-1',
          ref: 'BEL-7QK4M2',
          seatLabels: ['3A'],
        ),
      ],
      passengersMoved: 18,
      passengersLeft: rebookLeft,
    );
  }

  /// How many seats the rescue moved. Set per test — the console renders the
  /// difference between "everybody keeps their seat" and "nine people move".
  int rescueMoves = 0;

  @override
  Future<RescueAppliedDto> assignRescueCoach({
    required String departureId,
    required RescueCoachRequest request,
  }) async {
    saved.add('rescue:$departureId:${request.vehicleId}:${request.note ?? ''}');
    return RescueAppliedDto(
      departureId: departureId,
      registration: 'ODN-902',
      moves: [
        for (var i = 0; i < rescueMoves; i++)
          SeatMoveDto(from: '${i + 1}A', to: '${i + 1}E'),
      ],
      passengersTold: 1,
      ticketsReissued: rescueMoves,
      holdsReleased: 0,
    );
  }

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
    FileSaver? downloads,
  }) async {
    // A realistic agency laptop rather than the 800x600 default. The console
    // is a desktop product and testing it at a phone's width would either
    // fail honestly or push the layout into shapes no operator will see.
    // The screens still do not overflow at 800px — that is a separate
    // property and the reason every header is Expanded rather than Spacer'd.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final workspace = ConsoleWorkspace(
      gateway: gateway,
      files: files,
      downloads: downloads,
    );
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

  group('declaring a disruption', () {
    /// The sheet scrolls: on an agency laptop the confirm button is below the
    /// fold once the causes are showing, which is exactly where it is on a
    /// phone too.
    Future<void> confirm(WidgetTester tester) async {
      final button = find.widgetWithText(KButton, 'Signaler');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    _ScriptedConsole dispatcher({int sold = 42}) =>
        _ScriptedConsole(
            capabilities: const ['booking.read', 'disruption.declare'],
          )
          ..boardList = [
            DepartureBoardDto(
              id: 'dep-1',
              routeCode: 'BZV-PNR',
              departsAt: DateTime.utc(2026, 8, 10, 5),
              status: 'scheduled',
              capacity: 49,
              sold: sold,
              held: 0,
              available: 49 - sold,
              vehicle: 'ODN-001',
            ),
          ];

    testWidgets('a vendor is not offered the button at all', (tester) async {
      final gateway = _ScriptedConsole(capabilities: const ['booking.read'])
        ..boardList = dispatcher().boardList;

      await pump(tester, gateway);

      // Not greyed out, which invites a support call, and not visible and
      // 403ing, which teaches people our buttons lie (ADR-0011).
      expect(find.text('Signaler un incident'), findsNothing);
      expect(find.text('Liste'), findsOneWidget);
    });

    testWidgets('four taps declare a breakdown', (tester) async {
      final gateway = dispatcher();
      await pump(tester, gateway);

      await tester.tap(find.text('Signaler un incident'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Panne en route'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Panne mécanique'));
      await tester.pumpAndSettle();
      await confirm(tester);

      expect(
        gateway.saved,
        contains('disruption:dep-1:breakdownEnRoute:mechanical:'),
      );
    });

    testWidgets('what it will cost is shown before the button', (tester) async {
      await pump(tester, dispatcher());

      await tester.tap(find.text('Signaler un incident'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retard'));
      await tester.pumpAndSettle();

      // Thirty minutes entitles nobody to anything. The dispatcher is told
      // that at the moment they pick the offset, not by a counter agent an
      // hour later.
      await tester.tap(find.text('+30 min'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Moins d'une heure"), findsOneWidget);

      await tester.tap(find.text('+2 h'));
      await tester.pumpAndSettle();
      expect(find.textContaining('sans frais'), findsOneWidget);

      // And how many people this reaches, which is what turns "signalé" into
      // a fact somebody can act on.
      expect(find.textContaining('42 passager'), findsOneWidget);
    });

    testWidgets('a delay cannot be declared without a new time', (
      tester,
    ) async {
      final gateway = dispatcher();
      await pump(tester, gateway);

      await tester.tap(find.text('Signaler un incident'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Barrage / contrôle'));
      await tester.pumpAndSettle();

      // The domain refuses it on the server too. Refusing it here as well is
      // what stops a roadside request travelling to find that out on 2G.
      // Reads are not the claim — a dispatcher's console loads its agreements
      // on the way in — so what is asserted is that nothing was *sent*.
      await confirm(tester);
      expect(gateway.saved.where((s) => s.startsWith('disruption')), isEmpty);
    });

    testWidgets('the answer says how many were told', (tester) async {
      final gateway = dispatcher();
      await pump(tester, gateway);

      await tester.tap(find.text('Signaler un incident'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annulation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pas de car disponible'));
      await tester.pumpAndSettle();
      await confirm(tester);

      // "Signalé" on its own tells a dispatcher nothing.
      expect(find.textContaining('42 passager'), findsOneWidget);
      expect(find.textContaining('sans frais'), findsOneWidget);
    });

    testWidgets('a disrupted coach is marked on the day view', (tester) async {
      final gateway = dispatcher();
      gateway.boardList = [
        DepartureBoardDto(
          id: 'dep-1',
          routeCode: 'BZV-PNR',
          departsAt: DateTime.utc(2026, 8, 10, 5),
          status: 'scheduled',
          capacity: 49,
          sold: 42,
          held: 0,
          available: 7,
          vehicle: 'ODN-001',
          disruption: DisruptionDto(
            id: 'd-1',
            kind: DisruptionKind.breakdownEnRoute,
            cause: DisruptionCause.mechanical,
            declaredAt: DateTime.utc(2026, 8, 10, 5, 40),
            marksInvoluntary: true,
          ),
        ),
      ];

      await pump(tester, gateway);

      // Beside the route name, so a dispatcher glancing at the day does not
      // have to open a row to find out one of their coaches is broken down.
      expect(find.text('Panne en route'), findsOneWidget);
    });
  });

  group('sending a rescue coach', () {
    /// A dispatcher whose coach has broken down, plus a fleet to pick from.
    /// The 33-seater is deliberately too small for the 42 sold: the sheet has
    /// to say so rather than offering a swap the server will refuse.
    _ScriptedConsole stranded({int sold = 42, String? vehicle = 'ODN-001'}) =>
        _ScriptedConsole(
            capabilities: const ['booking.read', 'disruption.declare'],
          )
          ..vehicleList = const [
            VehicleDto(
              id: 'v-2',
              registration: 'ODN-902',
              layoutId: 'l-1',
              layoutName: 'Car 2+3, 55 places',
              capacity: 55,
              status: 'active',
              sellable: true,
            ),
            VehicleDto(
              id: 'v-3',
              registration: 'ODN-903',
              layoutId: 'l-2',
              layoutName: 'Minibus',
              capacity: 33,
              status: 'active',
              sellable: true,
            ),
            VehicleDto(
              id: 'v-4',
              registration: 'ODN-904',
              layoutId: 'l-1',
              layoutName: 'Car 2+3, 55 places',
              capacity: 55,
              status: 'maintenance',
              sellable: false,
            ),
          ]
          ..boardList = [
            DepartureBoardDto(
              id: 'dep-1',
              routeCode: 'BZV-PNR',
              departsAt: DateTime.utc(2026, 8, 10, 5),
              status: 'scheduled',
              capacity: 49,
              sold: sold,
              held: 0,
              available: 49 - sold,
              vehicle: vehicle,
              disruption: DisruptionDto(
                id: 'd-1',
                kind: DisruptionKind.breakdownEnRoute,
                cause: DisruptionCause.mechanical,
                declaredAt: DateTime.utc(2026, 8, 10, 5, 40),
                marksInvoluntary: true,
              ),
            ),
          ];

    testWidgets('a coach that is running is not offered a swap', (
      tester,
    ) async {
      final gateway = stranded()
        ..boardList[0] = DepartureBoardDto(
          id: 'dep-1',
          routeCode: 'BZV-PNR',
          departsAt: DateTime.utc(2026, 8, 10, 5),
          status: 'scheduled',
          capacity: 49,
          sold: 42,
          held: 0,
          available: 7,
          vehicle: 'ODN-001',
        );

      await pump(tester, gateway);

      // Every row on a normal day would otherwise carry a button that
      // re-signs forty-two tickets, and one of them gets pressed by mistake.
      expect(find.text('Car de secours'), findsNothing);
      expect(find.text('Signaler un incident'), findsOneWidget);
    });

    testWidgets('a departure with no coach at all offers one', (tester) async {
      await pump(tester, stranded(vehicle: null));
      expect(find.text('Car de secours'), findsOneWidget);
    });

    testWidgets('the sheet says which coaches everybody fits in', (
      tester,
    ) async {
      await pump(tester, stranded());

      await tester.tap(find.text('Car de secours'));
      await tester.pumpAndSettle();

      expect(find.text('55 places'), findsOneWidget);
      // Nine short of the forty-two sold, said as a number rather than as a
      // greyed-out row nobody can explain.
      expect(find.text('9 places de moins'), findsOneWidget);
      // A coach in maintenance is not a rescue, and offering it here would be
      // offering a swap the server is going to refuse.
      expect(find.text('ODN-904'), findsNothing);
    });

    testWidgets('choosing a coach sends it, and says who moved', (
      tester,
    ) async {
      final gateway = stranded()..rescueMoves = 9;
      await pump(tester, gateway);

      await tester.tap(find.text('Car de secours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ODN-902'));
      await tester.pumpAndSettle();

      final button = find.widgetWithText(KButton, 'Envoyer ce car');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('rescue:dep-1:v-2:'));
      // Never a bare success: nine people are sitting somewhere else, and
      // that is what the dispatcher is about to be asked about at the door.
      expect(find.textContaining('9 passager'), findsOneWidget);
    });

    testWidgets('a coach that is too small cannot be chosen', (tester) async {
      final gateway = stranded();
      await pump(tester, gateway);

      await tester.tap(find.text('Car de secours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ODN-903'));
      await tester.pumpAndSettle();

      // The confirm button stays disabled rather than travelling to the
      // server on 2G to be told the arithmetic the sheet already knows.
      final button = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Envoyer ce car'),
      );
      expect(button.onPressed, isNull);
      expect(gateway.saved.where((s) => s.startsWith('rescue')), isEmpty);
    });

    testWidgets('an operator with no spare is told so', (tester) async {
      final gateway = stranded()..vehicleList = const [];
      await pump(tester, gateway);

      await tester.tap(find.text('Car de secours'));
      await tester.pumpAndSettle();

      // The answer to a breakdown is then the counter, not this sheet — and
      // an empty list would have left the dispatcher looking for a scrollbar.
      expect(find.textContaining('Aucun car disponible'), findsOneWidget);
    });
  });

  group('moving the passengers onto another departure', () {
    /// A broken 06:00 with forty-two aboard, a 14:00 with eighteen free
    /// seats, and a departure on another road that must never be offered.
    _ScriptedConsole stranded() =>
        _ScriptedConsole(
            capabilities: const ['booking.read', 'disruption.declare'],
          )
          ..boardList = [
            DepartureBoardDto(
              id: 'dep-1',
              routeCode: 'BZV-PNR',
              departsAt: DateTime.utc(2026, 8, 10, 5),
              status: 'scheduled',
              capacity: 49,
              sold: 42,
              held: 0,
              available: 7,
              vehicle: 'ODN-001',
              disruption: DisruptionDto(
                id: 'd-1',
                kind: DisruptionKind.breakdownEnRoute,
                cause: DisruptionCause.mechanical,
                declaredAt: DateTime.utc(2026, 8, 10, 5, 40),
                marksInvoluntary: true,
              ),
            ),
            DepartureBoardDto(
              id: 'dep-2',
              routeCode: 'BZV-PNR',
              departsAt: DateTime.utc(2026, 8, 10, 13),
              status: 'scheduled',
              capacity: 49,
              sold: 31,
              held: 0,
              available: 18,
              vehicle: 'ODN-004',
            ),
            DepartureBoardDto(
              id: 'dep-3',
              routeCode: 'BZV-OYO',
              departsAt: DateTime.utc(2026, 8, 10, 14),
              status: 'scheduled',
              capacity: 49,
              sold: 0,
              held: 0,
              available: 49,
              vehicle: 'ODN-007',
            ),
          ];

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Reloger les passagers').first);
      await tester.pumpAndSettle();
    }

    /// Scoped to the sheet. The day board is still behind it and carries the
    /// same times and the same coach names, so an unscoped finder proves
    /// nothing about what the dispatcher is choosing from.
    Finder inSheet(Finder finder) =>
        find.descendant(of: find.byType(Dialog), matching: finder);

    testWidgets('only later departures on the same road are offered', (
      tester,
    ) async {
      await pump(tester, stranded());
      await open(tester);

      // 14h00 on the same road, with its coverage. The BZV-OYO at 14h00 is
      // a different journey however many seats it has, and the broken 06h00
      // cannot rescue itself.
      expect(inSheet(find.text('14h00')), findsOneWidget);
      expect(inSheet(find.text('18 sur 42')), findsOneWidget);
      expect(inSheet(find.text('ODN-007')), findsNothing);
    });

    testWidgets('choosing one sends it, and says who is left', (tester) async {
      final gateway = stranded()..rebookLeft = 24;
      await pump(tester, gateway);
      await open(tester);

      await tester.tap(inSheet(find.text('ODN-004')));
      await tester.pumpAndSettle();

      final button = find.widgetWithText(KButton, 'Reloger');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('rebook:dep-1:dep-2:'));
      // Partial coverage is the normal outcome, and the twenty-four still
      // standing at the roadside are the dispatcher's next problem — a
      // notice that said only "relogés" would hide them.
      expect(find.textContaining('24'), findsOneWidget);
    });

    testWidgets('a full day offers nothing, and says why', (tester) async {
      final gateway = stranded();
      // The 14:00 sold out while the dispatcher was on the phone.
      gateway.boardList = [gateway.boardList.first];
      await pump(tester, gateway);
      await open(tester);

      expect(find.textContaining('Aucun autre départ'), findsOneWidget);
      // And the confirm button cannot be pressed, rather than travelling to
      // the server to be told what the screen already knows.
      final button = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Reloger'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('the yards', () {
    _ScriptedConsole network() =>
        _ScriptedConsole(capabilities: const ['booking.read', 'route.manage'])
          ..stationList = const [
            StationDto(
              id: 'st-1',
              cityCode: 'BZV',
              name: 'Gare de Mikalou',
              boardingNotes: 'Guichet 3, derrière la station Total',
            ),
            StationDto(
              id: 'st-2',
              cityCode: 'BZV',
              name: 'Ancienne gare',
              active: false,
            ),
          ];

    testWidgets('the directions are on the row, not behind a tap', (
      tester,
    ) async {
      await pump(tester, network());
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      expect(find.text('Gare de Mikalou'), findsOneWidget);
      // The half of a station that a name cannot carry. Hiding it behind an
      // edit dialog would mean nobody checks it is still true.
      expect(find.text('Guichet 3, derrière la station Total'), findsOneWidget);
    });

    testWidgets('a closed yard is listed as closed, not removed', (
      tester,
    ) async {
      await pump(tester, network());
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      // Still there, and still reopenable: deleting it would erase where last
      // month's passengers were told to stand.
      expect(find.text('Ancienne gare'), findsOneWidget);
      expect(find.text('Fermée'), findsOneWidget);
    });

    testWidgets('closing one is a toggle, and it says what it did', (
      tester,
    ) async {
      final gateway = network();
      final workspace = await pump(tester, gateway);
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Fermer cette gare'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('station:BZV:Gare de Mikalou:false'));
      expect(workspace.notice, 'station.saved|Gare de Mikalou');
    });

    testWidgets('opening one asks for the city, the name and the way in', (
      tester,
    ) async {
      final gateway = network();
      await pump(tester, gateway);
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Nouvelle gare'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Ex. : Gare de Mikalou'),
        'Gare de Kinsoundi',
      );
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('station:BZV:Gare de Kinsoundi:true'));
    });
  });

  group('the towns on the road', () {
    _ScriptedConsole roads({List<RouteStopDto> stops = const []}) =>
        _ScriptedConsole(capabilities: const ['booking.read', 'route.manage'])
          ..routeList = [
            RouteDto(
              id: 'r-1',
              code: 'BZV-PNR',
              originCity: 'BZV',
              destinationCity: 'PNR',
              durationMinutes: 450,
              active: true,
              stops: stops,
            ),
          ];

    testWidgets('a direct road draws no itinerary line at all', (tester) async {
      // Most roads here are two towns and the tarmac between them. A line
      // printed on every row is a line nobody reads on the row that has one.
      await pump(tester, roads());
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Dolisie'), findsNothing);
    });

    testWidgets('a road with stops shows them, with their times', (
      tester,
    ) async {
      await pump(
        tester,
        roads(stops: const [RouteStopDto(cityCode: 'PNR', offsetMinutes: 315)]),
      );
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      // Named, and timed from the departure — which is the figure on the
      // timetable a dispatcher already holds.
      expect(find.textContaining('Pointe-Noire (5 h 15)'), findsOneWidget);
    });

    testWidgets('set down only says so on the row', (tester) async {
      // The detail every naive model gets wrong, and the one an operator
      // notices immediately. It is on the row rather than inside the dialog
      // because that is where somebody would spot it being wrong.
      await pump(
        tester,
        roads(
          stops: const [
            RouteStopDto(
              cityCode: 'PNR',
              offsetMinutes: 360,
              allowsBoarding: false,
            ),
          ],
        ),
      );
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('descente seule'), findsOneWidget);
    });

    testWidgets('adding a stop sends it with the road', (tester) async {
      final gateway = roads();
      await pump(tester, gateway);
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Modifier cette ligne'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ajouter un arrêt'));
      await tester.pumpAndSettle();

      // KField draws its label as a sibling of the field, not inside it, so
      // the field is found through the label's own card rather than by text.
      await tester.enterText(
        find.descendant(
          of: find.ancestor(
            of: find.text('Min. après le départ'),
            matching: find.byType(KField),
          ),
          matching: find.byType(TextField),
        ),
        '315',
      );
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(gateway.savedStops, hasLength(1));
      expect(gateway.savedStops!.single.offsetMinutes, 315);
    });

    testWidgets('removing the last stop still sends a list', (tester) async {
      // An empty list is how a stop is deleted. Omitting the field would
      // leave the road as it was, so the one screen that can remove a stop
      // would be unable to.
      final gateway = roads(
        stops: const [RouteStopDto(cityCode: 'PNR', offsetMinutes: 315)],
      );
      await pump(tester, gateway);
      await tester.tap(find.text('Lignes'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Modifier cette ligne'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Retirer cet arrêt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(gateway.savedStops, isEmpty);
    });
  });

  group('the statements screen', () {
    PayoutRunDto statement({int net = 3516000, String state = 'paid'}) =>
        PayoutRunDto(
          id: 'pay-1',
          operatorId: 'op-1',
          periodStart: DateTime.utc(2026, 8, 1),
          periodEnd: DateTime.utc(2026, 8, 8),
          onlineSalesCount: 412,
          onlineGross: const Money.xaf(3708000),
          cashSalesCount: 188,
          cashGross: const Money.xaf(1692000),
          commission: const Money.xaf(185400),
          serviceFees: const Money.xaf(180000),
          refunds: const Money.xaf(126000),
          payable: const Money.xaf(3708000),
          tills: const Money.xaf(192000),
          net: Money.xaf(net),
          state: state,
          preparedAt: DateTime.utc(2026, 8, 8, 9),
          paidAt: state == 'paid' ? DateTime.utc(2026, 8, 12) : null,
          reference: state == 'paid' ? 'MOMO-4471-88' : null,
        );

    _ScriptedConsole finance() =>
        _ScriptedConsole(capabilities: const ['booking.read', 'finance.read'])
          ..statementList = [statement()];

    testWidgets('the statement can be taken away as a document', (
      tester,
    ) async {
      final saver = _ScriptedSaver();
      final gateway = finance();
      await pump(tester, gateway, downloads: saver);
      await tester.tap(find.text('Versements'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Télécharger le relevé (PDF)'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('statementPdf:pay-1'));
      // The name is the server's. A commercial document named differently by
      // each surface is a folder nobody can search.
      expect(
        saver.saved.single.filename,
        'releve-ocean-du-nord-2026-08-01.pdf',
      );
      expect(saver.saved.single.mimeType, 'application/pdf');
      expect(saver.saved.single.bytes.take(4), [0x25, 0x50, 0x44, 0x46]);
    });

    testWidgets('and the console says which file it handed over', (
      tester,
    ) async {
      await pump(tester, finance(), downloads: _ScriptedSaver());
      await tester.tap(find.text('Versements'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Télécharger le relevé (PDF)'));
      await tester.pumpAndSettle();

      // A download in a browser is silent and easy to miss, especially on a
      // console where every other action changes the page.
      expect(
        find.textContaining('releve-ocean-du-nord-2026-08-01.pdf'),
        findsOneWidget,
      );
    });

    testWidgets('nowhere to save means no button, not a broken one', (
      tester,
    ) async {
      // Every build that is not the browser: a widget test, and one day a
      // desktop shell. A control that cannot hand anybody a file is worse
      // than no control.
      await pump(tester, finance());
      await tester.tap(find.text('Versements'));
      await tester.pumpAndSettle();

      expect(find.text('Télécharger le relevé (PDF)'), findsNothing);
      // The figures are still all there — the screen is not degraded, only
      // the one thing the platform cannot do is absent.
      expect(find.textContaining('Ventes guichet'), findsOneWidget);
    });

    testWidgets('a vendor is not offered the tab at all', (tester) async {
      await pump(
        tester,
        _ScriptedConsole(capabilities: const ['booking.read']),
      );

      // A vendor does not need to see what the company was paid last week,
      // and a tab they cannot use is a tab they eventually ask about.
      expect(find.text('Versements'), findsNothing);
    });

    testWidgets('the cash line is there, and says it is never paid out', (
      tester,
    ) async {
      final gateway = finance();
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.finance);
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('statements'));
      expect(find.textContaining('188 billet'), findsOneWidget);
      // The number one operator question, answered on the statement itself
      // rather than by a support call.
      expect(
        find.textContaining('vous détenez déjà cet argent'),
        findsOneWidget,
      );
      expect(find.textContaining('MOMO-4471-88'), findsOneWidget);
    });

    testWidgets('a week they owe us reads as owing, not as a payout', (
      tester,
    ) async {
      final gateway = finance()..statementList = [statement(net: -54000)];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.finance);
      await tester.pumpAndSettle();

      // Shown as a positive amount they owe rather than a payout with a minus
      // sign, which reads as money coming to them.
      expect(find.text('Vous nous devez ce montant'), findsOneWidget);
      // Positive, and it is the amount they owe. `Money.format` groups with
      // a narrow no-break space in French, so the assertion uses the same
      // character rather than a plain one that would never match.
      expect(find.textContaining('54${Money.narrowNbsp}000'), findsOneWidget);
    });
  });

  group('protection agreements', () {
    _ScriptedConsole dispatcher() =>
        _ScriptedConsole(capabilities: const ['booking.read']);

    _ScriptedConsole owner() => _ScriptedConsole(
      capabilities: const ['booking.read', 'protection.manage'],
    );

    testWidgets(
      'a dispatcher sees the tab, because option ③ is theirs to use',
      (tester) async {
        final gateway = dispatcher()..agreementList = [_agreement()];
        final workspace = await pump(tester, gateway);
        workspace.openSection(ConsoleSection.protection);
        await tester.pumpAndSettle();

        expect(gateway.saved, contains('protection'));
        expect(find.text('Trans Bony Voyages'), findsOneWidget);
        // Reading is theirs; agreeing a rate with a competitor is not.
        expect(find.text('Proposer un accord'), findsNothing);
      },
    );

    testWidgets('the rebill is money on a real fare, not basis points', (
      tester,
    ) async {
      final gateway = owner()..agreementList = [_agreement()];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      // 9 000 less 15% is 7 650 — a number somebody can check against a
      // ticket, which "1500 bps" is not.
      expect(find.textContaining('7${Money.narrowNbsp}650'), findsOneWidget);
      expect(find.textContaining('1500'), findsNothing);
    });

    testWidgets('the ceiling is shown before it bites', (tester) async {
      final gateway = owner()..agreementList = [_agreement(used: 31, cap: 40)];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      // On the card, not on the refusal: a dispatcher planning a rescue needs
      // to know the agreement is nearly spent while there is time to find
      // another one.
      expect(find.text('31 sur 40 places ce mois'), findsOneWidget);
    });

    testWidgets('our own proposal says nothing is covered yet', (tester) async {
      final gateway = owner()
        ..agreementList = [_agreement(state: 'proposed', weProposed: true)];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      expect(
        find.textContaining("Rien n'est couvert tant qu'ils n'ont pas accepté"),
        findsOneWidget,
      );
      // And there is nothing to accept — the party that wrote the terms is
      // not the party that agrees to them.
      expect(find.text('Accepter'), findsNothing);
    });

    testWidgets('theirs is offered with an accept and a decline', (
      tester,
    ) async {
      final gateway = owner()
        ..agreementList = [_agreement(state: 'proposed', weProposed: false)];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      expect(find.text('En attente de votre réponse'), findsOneWidget);
      expect(find.text('Refuser'), findsOneWidget);

      await tester.tap(find.text('Accepter'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('decide:agr-1:accept'));
      expect(
        find.textContaining('Accord avec Trans Bony Voyages en vigueur'),
        findsOneWidget,
      );
    });

    testWidgets('a live one can be suspended without being torn up', (
      tester,
    ) async {
      final gateway = owner()..agreementList = [_agreement()];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Suspendre'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('decide:agr-1:suspend'));
    });

    testWidgets('proposing sends a percentage as basis points', (tester) async {
      final gateway = owner()
        ..routeList = [
          const RouteDto(
            id: 'r-1',
            code: 'BZV-PNR',
            originCity: 'BZV',
            destinationCity: 'PNR',
            durationMinutes: 450,
            active: true,
          ),
        ];
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Proposer un accord'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'tbv');
      await tester.tap(find.text('BZV ↔ PNR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Envoyer la proposition'));
      await tester.pumpAndSettle();

      // Typed as "15" because that is how the term is spoken; stored as
      // 1500 because floating-point percentages are how an operator ends up
      // a franc short.
      expect(gateway.saved, contains('propose:TBV:BZV~PNR:1500'));
      expect(
        find.textContaining('Proposition envoyée à Trans Bony Voyages'),
        findsOneWidget,
      );
    });

    testWidgets('an operator with no routes is told why they cannot pick one', (
      tester,
    ) async {
      final workspace = await pump(tester, owner());
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Proposer un accord'));
      await tester.pumpAndSettle();

      expect(
        find.text("Créez d'abord une ligne : un accord couvre des trajets."),
        findsOneWidget,
      );
    });
  });

  group('asking another company for room', () {
    /// A dispatcher, a broken 06:00 with forty-two aboard, a live agreement
    /// on that road, and a competitor's 13:00 with six seats.
    _ScriptedConsole stranded() =>
        _ScriptedConsole(
            capabilities: const ['booking.read', 'disruption.declare'],
          )
          ..agreementList = [_agreement()]
          ..routeList = [
            const RouteDto(
              id: 'r-1',
              code: 'BZV-PNR',
              originCity: 'BZV',
              destinationCity: 'PNR',
              durationMinutes: 450,
              active: true,
            ),
          ]
          ..tripList = [_trip()]
          ..boardList = [
            DepartureBoardDto(
              id: 'dep-broken',
              routeCode: 'BZV-PNR',
              departsAt: DateTime.utc(2026, 8, 10, 5),
              status: 'scheduled',
              capacity: 49,
              sold: 42,
              held: 0,
              available: 7,
              vehicle: 'ODN-001',
              disruption: DisruptionDto(
                id: 'd-1',
                kind: DisruptionKind.breakdownEnRoute,
                cause: DisruptionCause.mechanical,
                declaredAt: DateTime.utc(2026, 8, 10, 5, 40),
                marksInvoluntary: true,
              ),
            ),
          ];

    Finder inSheet(Finder finder) =>
        find.descendant(of: find.byType(Dialog), matching: finder);

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Demander à une autre compagnie').first);
      await tester.pumpAndSettle();
    }

    testWidgets('the option is hidden when no agreement is in force', (
      tester,
    ) async {
      final gateway = stranded()..agreementList = const [];
      await pump(tester, gateway);

      // A button that opens onto "aucune compagnie" costs a dispatcher
      // fifteen seconds they do not have.
      expect(find.text('Demander à une autre compagnie'), findsNothing);
    });

    testWidgets('an exhausted ceiling hides it too', (tester) async {
      final gateway = stranded()..agreementList = [_agreement(used: 40)];
      await pump(tester, gateway);

      // In force and spent is refused all the same, until the first of the
      // month. Offering it at 05:40 is worse than not offering it.
      expect(find.text('Demander à une autre compagnie'), findsNothing);
    });

    testWidgets('the other company is offered with its live seat count', (
      tester,
    ) async {
      final gateway = stranded();
      await pump(tester, gateway);
      await open(tester);

      expect(gateway.saved, contains('trips:BZV:PNR'));
      expect(inSheet(find.text('Trans Bony Voyages')), findsOneWidget);
      expect(inSheet(find.textContaining('6 places libres')), findsOneWidget);
      // Coverage per candidate, before the choice: six seats for forty-two
      // people is a number the dispatcher acts on next.
      expect(inSheet(find.text('6 sur 42')), findsOneWidget);
    });

    testWidgets('a company we have no agreement with is never offered', (
      tester,
    ) async {
      final gateway = stranded()
        ..tripList = [
          _trip(id: 'dep-stranger', operatorId: 'op-x', operatorName: 'Autre'),
        ];
      await pump(tester, gateway);
      await open(tester);

      // The public search answers "who is going to Pointe-Noire". Only the
      // subset under an agreement is something a dispatcher can act on.
      expect(inSheet(find.text('Autre')), findsNothing);
      expect(find.textContaining('Aucune compagnie'), findsOneWidget);
    });

    testWidgets('sending it says plainly that nothing has moved yet', (
      tester,
    ) async {
      final gateway = stranded();
      await pump(tester, gateway);
      await open(tester);

      await tester.tap(inSheet(find.text('Trans Bony Voyages')));
      await tester.pumpAndSettle();

      // The warning is next to the button, before the tap — not in the
      // notice afterwards.
      expect(
        inSheet(find.textContaining("Rien ne bouge tant qu'ils")),
        findsOneWidget,
      );

      final button = find.widgetWithText(KButton, 'Demander');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('ask:dep-broken:dep-theirs:'));
      // And it says it again afterwards. A dispatcher who reads "envoyé" as
      // "placed" stops looking for a coach.
      expect(
        find.textContaining("Rien ne bouge tant qu'ils n'ont pas répondu"),
        findsOneWidget,
      );
    });
  });

  group('answering a protection request', () {
    _ScriptedConsole receiving() =>
        _ScriptedConsole(
            capabilities: const ['booking.read', 'disruption.declare'],
          )
          ..agreementList = [_agreement()]
          ..requestList = [_request()];

    Future<ConsoleWorkspace> openQueue(
      WidgetTester tester,
      _ScriptedConsole gateway,
    ) async {
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.protection);
      await tester.pumpAndSettle();
      return workspace;
    }

    testWidgets('carries what the dispatcher needs to answer', (tester) async {
      final gateway = receiving();
      await openQueue(tester, gateway);

      expect(gateway.saved, contains('requests'));
      expect(find.text('Ocean du Nord demande 2 place(s).'), findsOneWidget);
      // Their seat count and what we will be paid, on the card. A receiving
      // operator deciding blind is one who says no.
      expect(find.textContaining('6 libres'), findsOneWidget);
      expect(find.textContaining('15${Money.narrowNbsp}300'), findsOneWidget);
      // And the one thing about the button that is not obvious.
      expect(
        find.textContaining(
          'les passagers changent de compagnie tout de suite',
        ),
        findsOneWidget,
      );
    });

    testWidgets('accepting moves them, and says how many', (tester) async {
      final gateway = receiving();
      await openQueue(tester, gateway);

      await tester.tap(find.text('Accepter'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('decideRequest:req-1:accept'));
      expect(
        find.textContaining('2 passager(s) voyagent maintenant'),
        findsOneWidget,
      );
    });

    testWidgets('a coach that cannot take everybody says so twice', (
      tester,
    ) async {
      final gateway = receiving()
        ..requestList = [_request(seatsRequested: 5, seatsFree: 2)]
        ..movedSeats = 2;
      await openQueue(tester, gateway);

      // Before the decision…
      expect(find.textContaining('2 sur 5 seulement'), findsOneWidget);

      await tester.tap(find.text('Accepter'));
      await tester.pumpAndSettle();

      // …and after it, because the three still standing are somebody's next
      // problem and a notice that said only "acceptée" would hide them.
      expect(find.textContaining('2 sur 5 placés'), findsOneWidget);
    });

    testWidgets('a full coach cannot be accepted at all', (tester) async {
      final gateway = receiving()..requestList = [_request(seatsFree: 0)];
      await openQueue(tester, gateway);

      // Travelling to the server to be told what the screen already knows is
      // a promise made and broken in the same second.
      final accept = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Accepter'),
      );
      expect(accept.onPressed, isNull);
    });

    testWidgets('declining moves nobody', (tester) async {
      final gateway = receiving();
      await openQueue(tester, gateway);

      await tester.tap(find.text('Refuser'));
      await tester.pumpAndSettle();

      expect(gateway.saved, contains('decideRequest:req-1:decline'));
      expect(find.textContaining("Personne n'a été déplacé"), findsOneWidget);
    });

    testWidgets('our own ask is shown as waiting, with nothing to press', (
      tester,
    ) async {
      final gateway = receiving()
        ..requestList = [_request(weAsked: true, counterpartyName: 'TBV')];
      await openQueue(tester, gateway);

      expect(find.text('Vous demandez 2 place(s).'), findsOneWidget);
      expect(find.text('En attente'), findsOneWidget);
      // We do not answer our own ask, and the screen does not offer to.
      expect(find.text('Accepter'), findsNothing);
    });

    testWidgets('a decided request leaves the queue', (tester) async {
      final gateway = receiving()
        ..requestList = [_request(state: 'applied', seatsMoved: 2)];
      await openQueue(tester, gateway);

      // History on this screen is noise between a dispatcher and the coach
      // they are trying to fill.
      expect(find.text('Demandes en cours'), findsNothing);
    });

    testWidgets('the tab carries the count, because nobody is watching it', (
      tester,
    ) async {
      final gateway = receiving();
      await openQueue(tester, gateway);

      // A request nobody notices is a coachload nobody comes back for.
      expect(find.byType(Badge), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
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

  group('refunding at the counter', () {
    Finder fieldNamed(String label) => find.descendant(
      of: find.widgetWithText(KField, label),
      matching: find.byType(TextField),
    );

    Future<ConsoleWorkspace> openRefund(
      WidgetTester tester,
      _ScriptedConsole gateway,
    ) async {
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.counter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rembourser'));
      await tester.pumpAndSettle();
      return workspace;
    }

    _ScriptedConsole vendor() => _ScriptedConsole(
      capabilities: const ['booking.read', 'booking.sell', 'booking.refund'],
    );

    testWidgets('the quote is read before anything is agreed', (tester) async {
      final gateway = vendor()
        ..offerResult = RefundOfferDto(
          bookingRef: 'BEL-K4M2QX',
          state: 'confirmed',
          departsAt: DateTime.utc(2028, 3, 6),
          fare: const Money.xaf(9000),
          serviceFee: const Money.xaf(300),
          refundable: const Money.xaf(8100),
          retained: const Money.xaf(1200),
          rateBps: 9000,
          destination: 'agencyCash',
          policyName: 'Standard',
          policyLines: const ['policy.line.tier|48|90'],
        );
      await openRefund(tester, gateway);

      await tester.enterText(fieldNamed('Référence du billet'), 'BEL-K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voir ce qui est remboursable'));
      await tester.pumpAndSettle();

      expect(find.textContaining('8'), findsWidgets);
      expect(find.textContaining('Vendu sous : Standard'), findsOneWidget);
      // The terms the booking was sold under, rendered by the domain — the
      // same sentence the traveller read before paying.
      expect(
        find.textContaining('48 h avant le départ : 90 % remboursés'),
        findsOneWidget,
      );
      // Quoting is a read. Nothing has been refunded.
      expect(gateway.saved, contains('quote:BEL-K4M2QX'));
      expect(gateway.saved.where((s) => s.startsWith('refund:')), isEmpty);
    });

    testWidgets('a ticket outside the window shows the reason, not a zero', (
      tester,
    ) async {
      final gateway = vendor()
        ..offerResult = RefundOfferDto(
          bookingRef: 'BEL-K4M2QX',
          state: 'confirmed',
          departsAt: DateTime.utc(2028, 3, 6),
          fare: const Money.xaf(9000),
          serviceFee: const Money.xaf(300),
          failureCode: 'refund.outside_window',
        );
      await openRefund(tester, gateway);

      await tester.enterText(fieldNamed('Référence du billet'), 'BEL-K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voir ce qui est remboursable'));
      await tester.pumpAndSettle();

      // "0 FCFA" reads as a bug to the person being told it, and the vendor
      // has to repeat something true to somebody standing in front of them.
      expect(find.textContaining("n'est plus remboursable"), findsOneWidget);
      expect(find.text('Motif du remboursement'), findsNothing);
    });

    testWidgets('a refund needs a reason, and shows the claim code once', (
      tester,
    ) async {
      final gateway = vendor()
        ..offerResult = RefundOfferDto(
          bookingRef: 'BEL-K4M2QX',
          state: 'confirmed',
          departsAt: DateTime.utc(2028, 3, 6),
          fare: const Money.xaf(9000),
          serviceFee: const Money.xaf(300),
          refundable: const Money.xaf(8100),
          retained: const Money.xaf(1200),
          destination: 'agencyCash',
        );
      await openRefund(tester, gateway);

      await tester.enterText(fieldNamed('Référence du billet'), 'BEL-K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voir ce qui est remboursable'));
      await tester.pumpAndSettle();

      // "Why did we give this person money?" cannot be reconstructed later.
      final blocked = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Rembourser et annuler le billet'),
      );
      expect(blocked.onPressed, isNull);
      expect(find.text('Indiquez un motif.'), findsOneWidget);

      await tester.enterText(
        fieldNamed('Motif du remboursement'),
        'Voyageur a annulé au guichet',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(KButton, 'Rembourser et annuler le billet'),
      );
      await tester.pumpAndSettle();

      expect(
        gateway.saved,
        contains('refund:BEL-K4M2QX:Voyageur a annulé au guichet'),
      );
      // Blocking, and shown once: this code is the traveller's only way to
      // collect, and a vendor who dismisses the screen without reading it out
      // has left somebody with nothing.
      // Scoped to the dialog: the claim field below it carries the same
      // string as its hint, which is exactly the sample a vendor will see.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('K4M2QX'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('présente ce code'), findsOneWidget);
    });

    testWidgets('paying a claim takes the code and the vendor\'s station', (
      tester,
    ) async {
      final gateway = vendor();
      await openRefund(tester, gateway);

      await tester.enterText(fieldNamed('Code de remboursement'), 'K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(KButton, "Sortir l'argent de la caisse"),
      );
      await tester.pumpAndSettle();

      // The station is not a choice here: the money leaves the drawer the
      // vendor is scoped to and will count at the end of their shift.
      expect(gateway.saved, contains('claim:K4M2QX:st-bzv'));
    });

    testWidgets('the coach from the other yard is the one row that shouts', (
      tester,
    ) async {
      final gateway =
          _ScriptedConsole(
              capabilities: const [
                'booking.read',
                'booking.sell',
                'booking.reschedule',
              ],
            )
            ..missedResult = MissedOptionsDto(
              bookingRef: 'BEL-K4M2QX',
              originCity: 'BZV',
              destinationCity: 'PNR',
              seatsNeeded: 1,
              departedAt: DateTime.utc(2026, 8, 10, 5),
              paidFare: const Money.xaf(12000),
              fromStationName: 'Gare de Mikalou',
              terms: const ['policy.missed.fee|12|25'],
              options: [
                MissedOptionDto(
                  departureId: 'd-9',
                  departsAt: DateTime.utc(2026, 8, 10, 8, 30),
                  arrivesAt: DateTime.utc(2026, 8, 10, 16),
                  fare: const Money.xaf(12000),
                  seatsAvailable: 4,
                  stationName: 'Gare de Kinsoundi',
                  sameStation: false,
                  fee: const Money.xaf(3000),
                  fareDifference: const Money.xaf(0),
                  owed: const Money.xaf(3000),
                ),
              ],
            );
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.counter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Car raté'));
      await tester.pumpAndSettle();

      await tester.enterText(fieldNamed('Référence du billet'), 'BEL-K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chercher un autre car'));
      await tester.pumpAndSettle();

      // The company's own promise, read aloud before a price is quoted.
      expect(find.textContaining('dans les 12 h, contre 25 %'), findsOneWidget);
      // 08:30 UTC is 09h30 in Brazzaville, and the row an agent must not
      // misread: this coach leaves from the other side of the city.
      expect(find.textContaining('09h30'), findsOneWidget);
      expect(
        find.textContaining("Départ d'une autre gare : Gare de Kinsoundi"),
        findsOneWidget,
      );
      // Looking is a read. Nobody has been moved.
      expect(gateway.saved, contains('missedOptions:BEL-K4M2QX'));
      expect(gateway.saved.where((s) => s.startsWith('missedMove:')), isEmpty);
    });

    /// A screen with one later coach on it, priced at [owed].
    MissedOptionsDto oneCoach({required int owed}) => MissedOptionsDto(
      bookingRef: 'BEL-K4M2QX',
      originCity: 'BZV',
      destinationCity: 'PNR',
      seatsNeeded: 1,
      departedAt: DateTime.utc(2026, 8, 10, 5),
      paidFare: const Money.xaf(12000),
      options: [
        MissedOptionDto(
          departureId: 'd-9',
          departsAt: DateTime.utc(2026, 8, 10, 8, 30),
          arrivesAt: DateTime.utc(2026, 8, 10, 16),
          fare: const Money.xaf(12000),
          seatsAvailable: 4,
          fee: Money.xaf(owed),
          fareDifference: const Money.xaf(0),
          owed: Money.xaf(owed),
        ),
      ],
    );

    Future<void> moveMissed(
      WidgetTester tester,
      _ScriptedConsole gateway,
    ) async {
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.counter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Car raté'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Référence du billet'), 'BEL-K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chercher un autre car'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(KButton, 'Le mettre dessus'));
      await tester.pumpAndSettle();
    }

    _ScriptedConsole agent() => _ScriptedConsole(
      capabilities: const [
        'booking.read',
        'booking.sell',
        'booking.reschedule',
      ],
    );

    testWidgets('a paid transfer names the drawer that took it', (
      tester,
    ) async {
      final gateway = agent()..missedResult = oneCoach(owed: 3000);
      await moveMissed(tester, gateway);

      // Cash across a counter has to say which drawer counted it, and the
      // vendor is scoped to exactly one.
      expect(gateway.saved, contains('missedMove:BEL-K4M2QX:d-9:st-bzv'));
    });

    testWidgets('a free transfer names no drawer at all', (tester) async {
      final gateway = agent()..missedResult = oneCoach(owed: 0);
      await moveMissed(tester, gateway);

      // A till on a zero is a drawer nobody counted, and the server refuses
      // it — so the screen must not send one.
      expect(gateway.saved, contains('missedMove:BEL-K4M2QX:d-9:null'));
    });

    testWidgets('a company that never agreed to this says so, once', (
      tester,
    ) async {
      final gateway =
          _ScriptedConsole(
              capabilities: const [
                'booking.read',
                'booking.sell',
                'booking.reschedule',
              ],
            )
            ..missedResult = MissedOptionsDto(
              bookingRef: 'BEL-K4M2QX',
              originCity: 'BZV',
              destinationCity: 'PNR',
              seatsNeeded: 1,
              departedAt: DateTime.utc(2026, 8, 10, 5),
              paidFare: const Money.xaf(12000),
              options: const [],
              refusalCode: 'missed.not_offered',
            );
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.counter);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Car raté'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Référence du billet'), 'BEL-K4M2QX');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chercher un autre car'));
      await tester.pumpAndSettle();

      // One sentence, and no list of coaches underneath it to argue with.
      expect(
        find.textContaining('ne reporte pas un billet non utilisé'),
        findsOneWidget,
      );
      expect(find.widgetWithText(KButton, 'Le mettre dessus'), findsNothing);
    });

    testWidgets('a vendor who cannot reschedule is not offered the tab', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'booking.sell'],
      );
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.counter);
      await tester.pumpAndSettle();

      expect(find.text('Encaisser'), findsWidgets);
      expect(find.text('Car raté'), findsNothing);
    });

    testWidgets('a vendor who cannot refund is not offered the tab', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'booking.sell'],
      );
      final workspace = await pump(tester, gateway);
      workspace.openSection(ConsoleSection.counter);
      await tester.pumpAndSettle();

      expect(find.text('Encaisser'), findsWidgets);
      expect(find.text('Rembourser'), findsNothing);
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

    testWidgets('the change terms are answered in the same wizard', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Nom de ces conditions'), 'Maison');

      // Below the fold once the preset's two bands are drawn.
      await tester.ensureVisible(find.text('Changer de départ'));
      await tester.pumpAndSettle();

      // D-08's numbers are what the wizard opens on, so an operator who
      // answers nothing still writes the terms the platform applies anyway.
      expect(
        find.textContaining('Changement gratuit jusqu\'à 24 h'),
        findsOneWidget,
      );

      await tester.enterText(
        fieldNamed('Gratuit à plus de (heures avant le départ)'),
        '48',
      );
      await tester.enterText(fieldNamed('Frais ensuite (% du billet)'), '15');
      await tester.enterText(
        fieldNamed('Plus de changement à moins de (heures)'),
        '6',
      );
      await tester.pumpAndSettle();

      // The preview is the traveller's sentence, generated from the answer.
      expect(
        find.textContaining('Entre 6 h et 48 h avant le départ : 15 %'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.pumpAndSettle();

      // One save, one version: the refund bands and the change terms are
      // stamped onto a booking by the same (id, version) pair.
      expect(gateway.writtenChange!.freeBefore, const Duration(hours: 48));
      expect(gateway.writtenChange!.feeBps, 1500);
      expect(gateway.writtenChange!.cutoff, const Duration(hours: 6));
      expect(gateway.written!.tiers, hasLength(2));
    });

    testWidgets('a cutoff past the free window cannot be saved', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Nom de ces conditions'), 'Maison');
      await tester.ensureVisible(find.text('Changer de départ'));
      await tester.pumpAndSettle();

      // Both fields are individually reasonable. Together they charge a fee
      // between 48 h and 24 h before departure, inside a window the same
      // policy has already refused — and no single field could have caught it.
      await tester.enterText(
        fieldNamed('Plus de changement à moins de (heures)'),
        '48',
      );
      await tester.pumpAndSettle();

      final save = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Enregistrer'),
      );
      expect(save.onPressed, isNull);
      expect(gateway.writtenChange, isNull);
    });

    testWidgets('a stored policy reads its change terms too', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      )..policyList = [stored('Standard', isDefault: true)];
      await openPolicies(tester, gateway);

      // The operator answering "and if they want another coach?" reads it on
      // the same card as the refund bands, because it is the same version.
      expect(
        find.textContaining('Moins de 2 h avant le départ : changement'),
        findsOneWidget,
      );
      expect(
        find.textContaining('la compagnie modifie ou annule'),
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

    testWidgets('a missed coach is a question the wizard asks', (tester) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Nom de ces conditions'), 'Maison');

      await tester.ensureVisible(find.text('Un voyageur qui rate son car'));
      await tester.pumpAndSettle();

      // Zero and zero is what the wizard opens on, and it says so in a
      // sentence rather than leaving two empty boxes: not offering this is a
      // real answer, and the one every operator gives today.
      expect(
        find.textContaining("Un billet non utilisé au départ n'est pas"),
        findsOneWidget,
      );

      await tester.enterText(fieldNamed('Report possible pendant (h)'), '12');
      await tester.enterText(fieldNamed('Frais de report (%)'), '25');
      await tester.pumpAndSettle();

      // The preview is the sentence the agent will read aloud at the counter,
      // generated from the answer rather than typed by the operator.
      expect(find.textContaining('dans les 12 h, contre 25 %'), findsOneWidget);

      await tester.tap(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.pumpAndSettle();

      // Percent in, basis points out — and stamped onto the same version as
      // the refund bands beside it.
      expect(gateway.writtenMissed!.window, const Duration(hours: 12));
      expect(gateway.writtenMissed!.feeBps, 2500);
      expect(gateway.writtenMissed!.isOffered, isTrue);
    });

    testWidgets('an operator who answers nothing promises nothing', (
      tester,
    ) async {
      final gateway = _ScriptedConsole(
        capabilities: const ['booking.read', 'policy.manage'],
      );
      await openPolicies(tester, gateway);

      await tester.tap(find.text('Écrire des conditions'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldNamed('Nom de ces conditions'), 'Maison');
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.tap(find.widgetWithText(KButton, 'Enregistrer'));
      await tester.pumpAndSettle();

      // Honouring a missed ticket is a commercial promise. A wizard that
      // defaulted it to "yes" would be us making it on the company's behalf.
      expect(gateway.writtenMissed!.window, Duration.zero);
      expect(gateway.writtenMissed!.feeBps, 0);
      expect(gateway.writtenMissed!.isOffered, isFalse);
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

  group('self-signup', () {
    /// Far enough out that a certificate is valid whenever this runs.
    final expiry = DateTime.utc(2032, 3, 31);

    ApplicationFacts complete() => ApplicationFacts(
      legalName: 'Sotrapo SARL',
      rccmNumber: 'CG-BZV-01-2019-B12-00123',
      taxId: 'M2019110000123',
      legalForm: 'sarl',
      registeredAddress: '4 rue Fulbert Youlou, Dolisie',
      ownerName: 'Prosper Loubaki',
      ownerIdType: 'passport',
      ownerIdNumber: '19CD98765',
      ownerPhone: '+242060192286',
      ownerEmail: 'prosper@sotrapo.cg',
      transportLicenceNumber: 'TR-2025-0044',
      transportLicenceExpires: expiry,
      insurerName: 'NSIA Congo',
      fleetInsuranceExpires: expiry,
      routesServed: 'Dolisie - Pointe-Noire',
      fleetSize: 3,
      stationCount: 2,
      settlementKind: 'momo',
      settlementAccountName: 'Sotrapo',
      settlementAccountRef: '+242060192286',
      agreementAccepted: true,
    );

    OperatorApplicationDto application({
      required ApplicationFacts facts,
      String status = 'application_draft',
      String? decisionReason,
    }) => OperatorApplicationDto(
      operatorId: 'op-1',
      code: 'SOTRAP-K4M',
      status: status,
      facts: facts,
      createdAt: DateTime.utc(2030),
      decisionReason: decisionReason,
    );

    Future<OnboardingWorkspace> pumpWizard(
      WidgetTester tester,
      _ScriptedOnboarding gateway,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);

      final workspace = OnboardingWorkspace(
        gateway: gateway,
        clock: FixedClock(DateTime.utc(2030, 6, 1)),
      );
      await tester.pumpWidget(
        Localized(
          catalog: catalog,
          initialLanguage: 'fr',
          child: MaterialApp(
            theme: KiloTheme.materialTheme(),
            home: StreamBuilder<void>(
              stream: workspace.changes,
              builder: (context, _) => OnboardingScreen(workspace: workspace),
            ),
          ),
        ),
      );
      await workspace.load();
      await tester.pumpAndSettle();
      return workspace;
    }

    Finder fieldNamed(String label) => find.descendant(
      of: find.widgetWithText(KField, label),
      matching: find.byType(TextField),
    );

    testWidgets('an account with no application is asked one question', (
      tester,
    ) async {
      final gateway = _ScriptedOnboarding();
      await pumpWizard(tester, gateway);

      // Not six steps and an RCCM number. One field, because §2.1 wants
      // somebody looking at their own dossier inside fifteen minutes.
      expect(find.text('Vendre vos billets sur BilletEnLigne'), findsWidgets);
      expect(fieldNamed('Raison sociale'), findsOneWidget);
      expect(find.text('Entreprise'), findsNothing);

      await tester.enterText(fieldNamed('Raison sociale'), 'Sotrapo SARL');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Commencer'));
      await tester.pumpAndSettle();

      expect(gateway.calls, contains('start:Sotrapo SARL'));
      expect(find.text('Entreprise'), findsWidgets);
    });

    testWidgets('the checklist names what is missing, not how far you got', (
      tester,
    ) async {
      final gateway = _ScriptedOnboarding(
        existing: application(
          facts: const ApplicationFacts(legalName: 'Sotrapo SARL'),
        ),
      );
      await pumpWizard(tester, gateway);

      // The label a person reads, from the catalog — never the field name the
      // domain emitted.
      expect(
        find.textContaining('Numéro RCCM (registre du commerce)'),
        findsWidgets,
      );
      expect(find.textContaining('rccmNumber'), findsNothing);
    });

    testWidgets('an expired insurance certificate reads as missing', (
      tester,
    ) async {
      final gateway = _ScriptedOnboarding(
        existing: application(
          facts: complete().copyWith(
            fleetInsuranceExpires: DateTime.utc(2029, 12, 31),
          ),
        ),
      );
      final workspace = await pumpWizard(tester, gateway);

      // Present on the form and still outstanding: a date in the past reads
      // as answered on a checklist, which is worse than a blank.
      expect(workspace.missing, ['fleetInsuranceExpires']);
      expect(workspace.canSubmit, isFalse);
      expect(
        tester
            .widget<KButton>(find.widgetWithText(KButton, 'Envoyer le dossier'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('a complete application can be sent, and then locks', (
      tester,
    ) async {
      final gateway = _ScriptedOnboarding(
        existing: application(facts: complete()),
      );
      final workspace = await pumpWizard(tester, gateway);

      expect(workspace.canSubmit, isTrue);
      await tester.tap(find.text('Envoyer le dossier'));
      await tester.pumpAndSettle();

      expect(gateway.calls, contains('submit'));
      expect(workspace.isUnderReview, isTrue);
      expect(find.textContaining("en cours d'examen"), findsOneWidget);
      // Nothing to save and nothing to send while somebody is reading it.
      expect(find.text('Envoyer le dossier'), findsNothing);
    });

    testWidgets('typing is never blocked on a request', (tester) async {
      final gateway = _ScriptedOnboarding(
        existing: application(
          facts: const ApplicationFacts(legalName: 'Sotrapo SARL'),
        ),
      );
      final workspace = await pumpWizard(tester, gateway);

      await tester.enterText(
        fieldNamed('Numéro RCCM (registre du commerce)'),
        'CG-BZV-01-2019-B12-00123',
      );
      await tester.pumpAndSettle();

      // Held locally, and said out loud — somebody who closes the tab is
      // entitled to know whether the last two minutes are anywhere.
      expect(gateway.calls, isNot(contains('save')));
      expect(workspace.hasUnsavedChanges, isTrue);
      expect(find.text('Modifications non enregistrées'), findsOneWidget);

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();

      expect(gateway.calls, contains('save'));
      expect(workspace.facts.rccmNumber, 'CG-BZV-01-2019-B12-00123');
      expect(workspace.hasUnsavedChanges, isFalse);
    });

    testWidgets('clearing a field is a change the server hears about', (
      tester,
    ) async {
      final gateway = _ScriptedOnboarding(
        existing: application(
          facts: complete().copyWith(tradingName: 'Sotrapo'),
        ),
      );
      final workspace = await pumpWizard(tester, gateway);

      await tester.enterText(fieldNamed('Nom commercial'), '');
      await tester.pumpAndSettle();

      // The trap `copyWith` sets: a null there means "leave it alone", so a
      // deleted trading name would never reach the server.
      expect(workspace.facts.tradingName, isNull);
      expect(workspace.facts.legalName, 'Sotrapo SARL');
    });

    testWidgets("a reviewer's own words are quoted back", (tester) async {
      final gateway = _ScriptedOnboarding(
        existing: application(
          facts: complete(),
          status: 'info_requested',
          decisionReason: "L'attestation d'assurance est illisible",
        ),
      );
      final workspace = await pumpWizard(tester, gateway);

      expect(
        find.text("L'attestation d'assurance est illisible"),
        findsOneWidget,
      );
      // `info_requested` reopens the wizard exactly where the gap is — a
      // dossier that reopens read-only is a support call.
      expect(workspace.isUnderReview, isFalse);
    });
  });
}

/// An application the test holds in memory.
///
/// It enforces the two rules the server enforces — a locked application
/// refuses a save, and an incomplete one refuses a submit — because a fake
/// looser than the real thing teaches the screen habits the server will
/// refuse.
final class _ScriptedOnboarding implements OnboardingGateway {
  _ScriptedOnboarding({this.existing});

  OperatorApplicationDto? existing;
  final calls = <String>[];

  @override
  Future<OperatorApplicationDto?> mine() async {
    calls.add('mine');
    return existing;
  }

  @override
  Future<OperatorApplicationDto> start(String legalName) async {
    calls.add('start:$legalName');
    return existing = OperatorApplicationDto(
      operatorId: 'op-new',
      code: 'SOTRAP-K4M',
      status: 'application_draft',
      facts: ApplicationFacts(legalName: legalName),
      createdAt: DateTime.utc(2030),
    );
  }

  @override
  Future<OperatorApplicationDto> save(ApplicationFacts facts) async {
    calls.add('save');
    final current = existing!;
    if (!current.isEditable) {
      throw const ServerRefused(
        409,
        ApiError(code: ErrorCode.applicationLocked),
      );
    }
    return existing = OperatorApplicationDto(
      operatorId: current.operatorId,
      code: current.code,
      status: current.status,
      facts: facts,
      createdAt: current.createdAt,
    );
  }

  @override
  Future<OperatorApplicationDto> submit() async {
    calls.add('submit');
    final current = existing!;
    if (!current.facts.isSubmittable(asOf: DateTime.utc(2030))) {
      throw const ServerRefused(
        409,
        ApiError(code: ErrorCode.applicationIncomplete),
      );
    }
    return existing = OperatorApplicationDto(
      operatorId: current.operatorId,
      code: current.code,
      status: 'under_review',
      facts: current.facts,
      createdAt: current.createdAt,
      submittedAt: DateTime.utc(2030, 1, 2),
    );
  }
}

/// A file dialog that has already decided.
/// Where a downloaded file goes in a test. The browser's own anchor-and-blob
/// is the one thing in the download path a widget test cannot run, which is
/// exactly why it is behind a port.
final class _ScriptedSaver implements FileSaver {
  final saved = <({String filename, List<int> bytes, String mimeType})>[];

  @override
  Future<void> save({
    required String filename,
    required List<int> bytes,
    required String mimeType,
  }) async => saved.add((filename: filename, bytes: bytes, mimeType: mimeType));
}

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

/// One request, as the other company's console would receive it.
ProtectionRequestDto _request({
  String id = 'req-1',
  String state = 'pending',
  bool weAsked = false,
  String counterpartyName = 'Ocean du Nord',
  int seatsRequested = 2,
  int seatsFree = 6,
  int? seatsMoved,
  String? note,
  String? declineReason,
}) => ProtectionRequestDto(
  id: id,
  agreementId: 'agr-1',
  counterpartyName: counterpartyName,
  weAsked: weAsked,
  fromDepartureId: 'dep-broken',
  toDepartureId: 'dep-theirs',
  seatsRequested: seatsRequested,
  state: state,
  requestedAt: DateTime.utc(2026, 8, 10, 5, 40),
  note: note,
  routeCode: 'BZV-PNR',
  departsAt: DateTime.utc(2026, 8, 10, 5),
  replacementDepartsAt: DateTime.utc(2026, 8, 10, 13),
  seatsFree: seatsFree,
  rebill: const Money.xaf(15300),
  seatsMoved: seatsMoved,
  declineReason: declineReason,
);

/// A competitor's departure, as the public search returns it.
DepartureSummaryDto _trip({
  String id = 'dep-theirs',
  String operatorId = 'op-bony',
  String operatorName = 'Trans Bony Voyages',
  int seatsAvailable = 6,
  DateTime? departsAt,
}) => DepartureSummaryDto(
  id: id,
  operatorId: operatorId,
  operatorName: operatorName,
  mode: 'bus',
  originCity: 'BZV',
  destinationCity: 'PNR',
  departsAt: departsAt ?? DateTime.utc(2026, 8, 10, 13),
  arrivesAt: (departsAt ?? DateTime.utc(2026, 8, 10, 13)).add(
    const Duration(hours: 8),
  ),
  fare: const Money.xaf(9000),
  serviceFee: const Money.xaf(300),
  seatsAvailable: seatsAvailable,
  capacity: 49,
  seatSelectionEnabled: true,
);

/// One agreement, with the terms `08-disruption.md` §5 writes down.
ProtectionAgreementDto _agreement({
  String id = 'agr-1',
  String state = 'active',
  bool weProposed = true,
  String counterpartyName = 'Trans Bony Voyages',
  List<String> corridors = const ['BZV~PNR'],
  int discountBps = 1500,
  int? cap = 40,
  int used = 0,
}) => ProtectionAgreementDto(
  id: id,
  counterpartyId: 'op-bony',
  counterpartyName: counterpartyName,
  state: state,
  corridors: corridors,
  reciprocal: true,
  rebillDiscountBps: discountBps,
  weProposed: weProposed,
  proposedAt: DateTime.utc(2026, 8, 1),
  seatsUsedThisMonth: used,
  monthlyCapSeats: cap,
  acceptedAt: state == 'proposed' ? null : DateTime.utc(2026, 8, 2),
);
