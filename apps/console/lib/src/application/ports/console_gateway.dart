import 'package:bel_domain/bel_domain.dart';
import 'package:bel_contracts/bel_contracts.dart';

/// Everything the console needs from the outside world.
///
/// One port, like the traveller app's `TravelGateway` and for the same
/// reason: these calls are one conversation. A layout leads to a vehicle
/// leads to a route leads to a timetable leads to departures, and every
/// screen is a step in it. Four ports would mean four fakes to keep
/// consistent, and the moment two of them disagree the tests mean nothing.
abstract interface class ConsoleGateway {
  /// Who is signed in and what they may do. Rendered into navigation and
  /// never trusted as authority — every route re-checks server-side.
  Future<ConsoleIdentityDto> identity();

  Future<List<LayoutDto>> layouts();

  Future<LayoutDto> saveLayout({
    required String name,
    required String preset,
    int? rows,
  });

  Future<LayoutDto> drawLayout(LayoutDraft draft);

  Future<RefundOfferDto> refundOffer(String bookingRef);

  Future<IssuedRefundDto> refundBooking({
    required String bookingRef,
    required String reason,
  });

  Future<ClaimedRefundDto> claimRefund({
    required String claimCode,
    required String stationId,
  });

  Future<({List<RefundPolicyDto> items, bool hasDefault})> refundPolicies();

  Future<RefundPolicyDto> saveRefundPolicy({
    required String name,
    required RefundPolicy policy,
    ChangePolicy change,
  });

  /// Null when the default was cleared — a legitimate state, not a failure.
  Future<RefundPolicyDto?> setDefaultRefundPolicy({
    String? policyId,
    int? version,
  });

  /// Move the passengers of a broken departure onto another of this
  /// operator's. Partial coverage is a success, and says how many are left.
  Future<RebookingAppliedDto> rebookOnto({
    required String departureId,
    required RebookRequest request,
  });

  /// Send a different coach on a departure that has lost its own, remapping
  /// everybody who is already on it.
  Future<RescueAppliedDto> assignRescueCoach({
    required String departureId,
    required RescueCoachRequest request,
  });

  /// This operator's own payout statements, newest first. A read, and only a
  /// read — there is no write on this port because there is no route.
  Future<List<PayoutRunDto>> statements();

  /// One statement as the document an accountant files (`04-payments.md`
  /// §6.2). Bytes and the name the *server* chose for them.
  Future<({List<int> bytes, String filename, String mimeType})> statementPdf(
    String runId,
  );

  /// Standing protection agreements, in either role (`08-disruption.md` §5).
  Future<List<ProtectionAgreementDto>> protectionAgreements();

  Future<ProtectionAgreementDto> proposeAgreement(
    ProposeAgreementRequest request,
  );

  /// `accept` · `decline` · `suspend` · `resume` · `end`.
  Future<ProtectionAgreementDto> decideAgreement({
    required String agreementId,
    required AgreementDecisionRequest request,
  });

  /// Protection requests in either direction (`08-disruption.md` §2.3).
  ///
  /// One list, not an inbox and an outbox: the same row is what we are
  /// waiting on and what they are waiting on.
  Future<List<ProtectionRequestDto>> protectionRequests();

  /// Ask another company for room on one of their coaches.
  Future<ProtectionRequestDto> askForProtection(ProtectionRequestBody request);

  /// `accept` or `decline`. Accepting moves the passengers in the same call.
  Future<ProtectionRequestDto> decideProtectionRequest({
    required String requestId,
    required AgreementDecisionRequest request,
  });

  /// Everybody's departures on a road, for a local day — the public search,
  /// asked from the console.
  ///
  /// The only place the console reads another company's timetable, and it
  /// reads it exactly where a traveller would: a dispatcher looking for a
  /// competitor with room is doing what any passenger with the app could do,
  /// so there is nothing here to widen.
  Future<List<DepartureSummaryDto>> tripsOn({
    required String originCity,
    required String destinationCity,
    required DateTime date,
  });

  Future<List<VehicleDto>> vehicles();

  Future<VehicleDto> saveVehicle({
    required String registration,
    required String layoutId,
    String? nickname,
    String? model,
  });

  /// Returns the future departures the coach was carrying, so the screen can
  /// say what is now uncrewed rather than reporting a bare success.
  Future<List<String>> setVehicleStatus({
    required String vehicleId,
    required String status,
  });

  Future<List<RouteDto>> routes();

  Future<RouteDto> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
  });

  Future<List<CityDto>> cities();

  Future<List<ScheduleDto>> schedules();

  Future<ScheduleDto> saveSchedule({
    required String routeId,
    required String rrule,
    required String departureTime,
    required int fareMinor,
    required DateTime validFrom,
    String? vehicleId,
    DateTime? validUntil,
  });

  Future<MaterialisationDto> materialise({
    required String scheduleId,
    required DateTime from,
    required DateTime to,
  });

  Future<List<DepartureBoardDto>> board(DateTime localDate);

  Future<ManifestDto> manifest(String departureId);

  /// Declares a disruption on a departure (`08-disruption.md` §2.1).
  Future<DeclaredDisruptionDto> declareDisruption({
    required String departureId,
    required DeclareDisruptionRequest request,
  });

  Future<SeatMapDto> seatMap(String departureId);

  Future<CounterSaleDto> collect({
    required String paymentCode,
    required String stationId,
  });

  /// The operator's storefront, and the change they made to it.
  ///
  /// On this port rather than a second one because the vitrine editor is a
  /// console screen like any other — and because its live preview is the
  /// reason the screen sells the platform in a demo, which only works if the
  /// preview and the save go through the same conversation.
  Future<VitrineDto> vitrine();

  Future<VitrineDto> saveVitrine(SaveVitrineRequest request);

  /// Uploads a logo or a cover, and answers with the whole vitrine.
  ///
  /// The whole vitrine rather than a URL, so the preview re-renders from one
  /// response instead of stitching a new URL into state it already holds —
  /// and so a rejected upload leaves the screen showing what is actually
  /// stored rather than what was attempted.
  Future<VitrineDto> uploadVitrineAsset({
    required String asset,
    required List<int> bytes,
    required String mimeType,
  });

  Future<VitrineDto> removeVitrineAsset(String asset);

  Future<CounterSaleDto> sell({
    required String departureId,
    required String buyerPhone,
    required List<PassengerDto> passengers,
    required String stationId,
    required String idempotencyKey,
  });
}
