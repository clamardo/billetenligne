import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_console/src/application/ports/console_gateway.dart';
import 'package:bel_domain/bel_domain.dart';

/// A gateway the test drives directly.
///
/// Scripted rather than a demo twin, unlike the traveller app's: there is no
/// demo console (`main.dart` says why — a fake one would be a second
/// definition of every coach and route), so the only fake that should exist
/// is one a test controls completely.
final class ScriptedConsole implements ConsoleGateway {
  ScriptedConsole({required this.capabilities});

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

  /// Nothing dated by default. A test that wants the banner sets this.
  ComplianceDto standing = const ComplianceDto(
    operatorId: 'op-1',
    stage: 'clear',
  );

  @override
  Future<ComplianceDto> compliance() async => standing;

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

  /// And what it priced. Null and empty are different answers — one leaves
  /// the list alone, the other takes every leg off sale.
  List<SegmentFareDto>? savedSegments;

  @override
  Future<RouteDto> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    List<RouteStopDto>? stops,
    List<SegmentFareDto>? segments,
  }) async {
    saved.add('route:$code');
    savedStops = stops;
    savedSegments = segments;
    return RouteDto(
      id: id ?? 'r-1',
      code: code,
      originCity: originCity,
      destinationCity: destinationCity,
      durationMinutes: durationMinutes,
      active: true,
      stops: stops ?? const [],
      segments: [
        for (final fare in segments ?? const <SegmentFareDto>[])
          SegmentFareDto(
            fromCity: fare.fromCity,
            toCity: fare.toCity,
            fareMinor: fare.fareMinor,
            fromPosition: 0,
            toPosition: 1,
          ),
      ],
    );
  }

  @override
  Future<List<CityDto>> cities() async => const [
    CityDto(code: 'BZV', name: 'Brazzaville'),
    CityDto(code: 'PNR', name: 'Pointe-Noire'),
    // A third town, so a road can have something between its endpoints: a
    // stop dropdown offering only the two ends cannot describe a road that
    // passes through anywhere.
    CityDto(code: 'DOL', name: 'Dolisie'),
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
      // Somebody who bought a piece of the road and gets off at Dolisie.
      ManifestPassengerDto(
        seatLabel: '2B',
        passengerName: 'Serge N.',
        bookingRef: 'BEL-3RT9P1',
        boarded: false,
        boardsAt: 'BZV',
        alightsAt: 'DOL',
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
    return protectionAgreement(
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
    return protectionAgreement(
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
    return protectionRequest(id: 'req-new');
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
    return protectionRequest(
      id: requestId,
      state: request.decision == 'accept' ? 'applied' : 'declined',
      seatsRequested: asked ?? 2,
      seatsMoved: request.decision == 'accept'
          ? movedSeats ?? asked ?? 2
          : null,
      declineReason: request.reason,
    );
  }

  /// The open-call inbox, and whether this operator is in the channel.
  OpenCallsDto callInbox = const OpenCallsDto(receiving: false, calls: []);

  @override
  Future<OpenCallsDto> openProtectionCalls() async {
    saved.add('openCalls');
    return callInbox;
  }

  @override
  Future<OpenCallDto> openProtectionCall(OpenCallBody body) async {
    saved.add('openCall:${body.departureId}');
    return openCall(id: 'call-new', weOpened: true);
  }

  @override
  Future<OpenCallDto> withdrawProtectionCall(String callId) async {
    saved.add('withdrawCall:$callId');
    return openCall(id: callId, weOpened: true, state: 'withdrawn');
  }

  @override
  Future<ProtectionRequestDto> answerProtectionCall({
    required String callId,
    required AnswerCallBody body,
  }) async {
    saved.add('answerCall:$callId:${body.replacementDepartureId}');
    return protectionRequest(
      id: 'req-answered',
      state: 'applied',
      seatsMoved: 2,
    );
  }

  @override
  Future<bool> receiveOpenProtectionCalls(bool receiving) async {
    saved.add('receiving:$receiving');
    callInbox = OpenCallsDto(receiving: receiving, calls: callInbox.calls);
    return receiving;
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
    // Only the asset that was sent comes back with a URL. A fake that lit up
    // both would hide a screen wiring the cover button to the logo field.
    return vitrineRow = vitrineRow.withAssetUrls(
      logoUrl: asset == 'logo'
          ? 'https://storage.test/operators/op-1/logo.png'
          : vitrineRow.logoUrl,
      coverUrl: asset == 'cover'
          ? 'https://storage.test/operators/op-1/cover.jpg'
          : vitrineRow.coverUrl,
    );
  }

  @override
  Future<VitrineDto> removeVitrineAsset(String asset) async {
    saved.add('remove:$asset');
    return vitrineRow = vitrineRow.withAssetUrls(
      logoUrl: asset == 'logo' ? null : vitrineRow.logoUrl,
      coverUrl: asset == 'cover' ? null : vitrineRow.coverUrl,
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

  /// The address the vendor typed, echoed. The real server answers with what
  /// it actually sent to, which on an empty field is the account's own.
  @override
  Future<TicketLinkSentDto> sendTicketLink({
    required String bookingRef,
    required String channel,
    String? sendTo,
  }) async {
    saved.add('link:$bookingRef:$channel:${sendTo ?? ''}');
    return TicketLinkSentDto(
      channel: channel,
      sentTo: sendTo ?? '+242069000001',
    );
  }

  @override
  Future<void> revokeTicketLinks(String bookingRef) async {
    saved.add('unlink:$bookingRef');
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

/// One request, as the other company's console would receive it.
ProtectionRequestDto protectionRequest({
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

/// An open call, as either console reads it.
OpenCallDto openCall({
  String id = 'call-1',
  bool weOpened = false,
  String state = 'open',
  String sendingOperatorName = 'Ocean du Nord',
  int seatsRequested = 12,
  String? note,
}) => OpenCallDto(
  id: id,
  sendingOperatorName: sendingOperatorName,
  weOpened: weOpened,
  fromDepartureId: 'dep-broken',
  originCity: 'BZV',
  destinationCity: 'PNR',
  seatsRequested: seatsRequested,
  rebillPerSeat: const Money.xaf(12000),
  state: state,
  openedAt: DateTime.utc(2026, 8, 10, 5, 40),
  expiresAt: DateTime.utc(2026, 8, 10, 7, 40),
  note: note,
  departsAt: DateTime.utc(2026, 8, 10, 6),
);

/// One agreement, with the terms `08-disruption.md` §5 writes down.
ProtectionAgreementDto protectionAgreement({
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
