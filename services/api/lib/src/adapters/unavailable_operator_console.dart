import 'package:bel_domain/bel_domain.dart';

import '../application/ports/disruption_desk.dart';
import '../application/ports/payout_desk.dart';
import '../application/ports/operator_console.dart';
import '../application/ports/ticket_links.dart';
import '../application/ports/platform_console.dart';

/// What the console surface resolves to when there is no database.
///
/// The fakes composition exists so a fresh clone can browse, hold and reserve
/// with nothing installed (`composition.dart`). The console is different in
/// kind: it *configures* the world the traveller browses — coaches, routes,
/// timetables — and a fake one would be a second, diverging definition of
/// every one of those, kept in sync by hand and wrong the first week nobody
/// remembered to.
///
/// So it refuses instead, and says why. Every method throws
/// [ConsoleRequiresDatabase], which the route layer turns into a 503 with a
/// message naming `DATABASE_URL` — which is a far better afternoon than a
/// console that silently accepts a coach and forgets it on restart.
final class UnavailableOperatorConsole implements OperatorConsole {
  const UnavailableOperatorConsole();

  Never _refuse() => throw const ConsoleRequiresDatabase();

  @override
  Future<List<LayoutSummary>> layouts(String operatorId) async => _refuse();

  @override
  Future<LayoutSummary> saveLayout({
    required String operatorId,
    required String name,
    required SeatLayout layout,
  }) async => _refuse();

  @override
  Future<List<VehicleSummary>> vehicles(String operatorId) async => _refuse();

  @override
  Future<VehicleSummary?> saveVehicle({
    required String operatorId,
    required String registration,
    required String layoutId,
    String? id,
    String? nickname,
    String? model,
    List<String> amenities = const [],
  }) async => _refuse();

  @override
  Future<List<String>> setVehicleStatus({
    required String operatorId,
    required String vehicleId,
    required String status,
  }) async => _refuse();

  @override
  Future<List<RouteSummary>> routes(String operatorId) async => _refuse();

  @override
  Future<RouteSummary?> saveRoute({
    required String operatorId,
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    int? distanceKm,
    Itinerary? stops,
    SegmentPricing? segments,
  }) async => _refuse();

  @override
  Future<List<StationSummary>> stations(String operatorId) async => _refuse();

  @override
  Future<StationSummary?> saveStation({
    required String operatorId,
    required String cityCode,
    required String name,
    String? id,
    double? lat,
    double? lng,
    String? boardingNotes,
    bool active = true,
  }) async => _refuse();

  @override
  Future<List<PatternSummary>> patterns(String operatorId) async => _refuse();

  @override
  Future<PatternSummary?> savePattern({
    required String operatorId,
    required String routeId,
    required Recurrence recurrence,
    required String departureTime,
    required Money fare,
    required DateTime validFrom,
    String? id,
    String? vehicleId,
    DateTime? validUntil,
    String? originStationId,
    String? destinationStationId,
  }) async => _refuse();

  @override
  Future<MaterialisationReport> materialise({
    required String operatorId,
    required String patternId,
    required DateTime from,
    required DateTime to,
  }) async => _refuse();

  @override
  Future<List<DepartureBoardRow>> board({
    required String operatorId,
    required DateTime localDate,
  }) async => _refuse();

  @override
  Future<Manifest?> manifest({
    required String operatorId,
    required String departureId,
  }) async => _refuse();

  @override
  Future<({List<String> recorded, List<String> unknown})> recordBoardings({
    required String operatorId,
    required String departureId,
    required String? scannedByUserId,
    required List<Boarding> boardings,
  }) async => _refuse();

  @override
  Future<BoardingManifestData?> boardingManifest({
    required String operatorId,
    required String departureId,
  }) async => _refuse();

  @override
  Future<List<RefundPolicySummary>> refundPolicies(String operatorId) async =>
      _refuse();

  @override
  Future<RefundPolicySummary> saveRefundPolicy({
    required String operatorId,
    required String name,
    required RefundPolicy policy,
    required String actorUserId,
    ChangePolicy change = ChangePolicy.standard,
    MissedPolicy missed = MissedPolicy.notOffered,
  }) async => _refuse();

  @override
  Future<RefundPolicySummary?> setDefaultRefundPolicy({
    required String operatorId,
    required String? policyId,
    required int? version,
  }) async => _refuse();

  @override
  Future<RefundOffer?> quoteRefund({
    required String operatorId,
    required String bookingRef,
    required DateTime now,
  }) async => _refuse();

  @override
  Future<IssuedRefund?> refundBooking({
    required String operatorId,
    required String bookingRef,
    required String actorUserId,
    required String reason,
    required DateTime now,
  }) async => _refuse();

  @override
  Future<ClaimedRefund?> claimRefund({
    required String operatorId,
    required String claimCode,
    required String stationId,
    required String actorUserId,
    required DateTime now,
  }) async => _refuse();

  @override
  Future<List<PaymentAccountSummary>> paymentAccounts(
    String operatorId,
  ) async => _refuse();

  @override
  Future<PaymentAccountSummary?> savePaymentAccount({
    required String operatorId,
    required String railId,
    required String msisdn,
    required String displayName,
  }) async => _refuse();
}

/// The console needs a real database and there is not one.
final class ConsoleRequiresDatabase implements Exception {
  const ConsoleRequiresDatabase();

  @override
  String toString() =>
      'The operator console requires a database. Set DATABASE_URL and run '
      'the migrations; the fakes composition serves the traveller surface '
      'only.';
}

/// The same refusal, for the back office.
///
/// The admin surface reads across every tenant and writes an audit row for
/// each read. Neither is meaningful against fakes, so it refuses in the same
/// voice rather than serving an invented queue that a reviewer might believe.
final class UnavailablePlatformConsole implements PlatformConsole {
  const UnavailablePlatformConsole();

  Never _refuse() => throw const ConsoleRequiresDatabase();

  @override
  Future<List<OperatorSummary>> operators({
    required String actorUserId,
    Set<String> statuses = const {},
  }) async => _refuse();

  @override
  Future<OperatorDetail?> operatorDetail(
    String operatorId, {
    required String actorUserId,
  }) async => _refuse();

  @override
  Future<Result<OperatorSummary, DecisionRefusal>> decide({
    required String operatorId,
    required OperatorDecision decision,
    required String actorUserId,
    required String reason,
    String? detail,
  }) async => _refuse();

  @override
  Future<Result<OperatorSummary, DecisionRefusal>> setCommission({
    required String operatorId,
    required CommissionTerm term,
    required String actorUserId,
    required String reason,
  }) async => _refuse();

  @override
  Future<List<FunnelDay>> funnel({
    required String actorUserId,
    int days = 14,
    String? operatorId,
    String channel = 'app',
  }) async => _refuse();

  @override
  Future<List<UnresolvedPayment>> unresolvedPayments({
    required String actorUserId,
    int limit = 100,
  }) async => _refuse();

  @override
  Future<UnresolvedPayment?> unresolvedPayment(
    String intentId, {
    required String actorUserId,
  }) async => _refuse();

  @override
  Future<void> recordRead({
    required String actorUserId,
    required String reason,
    required String action,
    String? subjectType,
    String? subjectId,
    String? operatorId,
    String? traceId,
  }) async => _refuse();
}

/// What the dispatcher's disruption desk resolves to with no database.
///
/// Same argument as the console above, and one more: declaring a disruption
/// marks bookings, moves a departure and queues a message to every passenger
/// on it. A fake that accepted one would answer "42 passagers prévenus" to a
/// dispatcher standing at a roadside, having told nobody.
final class UnavailableDisruptionDesk implements DisruptionDesk {
  const UnavailableDisruptionDesk();

  @override
  Future<Result<DisruptionRecord, DeclarationRefusal>> declare({
    required String operatorId,
    required String departureId,
    required DisruptionKind kind,
    required DisruptionCause cause,
    required String actorUserId,
    required DateTime now,
    String? note,
    String? location,
    DateTime? revisedDepartsAt,
    DateTime? estimatedResolution,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<Result<RescueApplied, DeclarationRefusal>> assignRescueCoach({
    required String operatorId,
    required String departureId,
    required String vehicleId,
    required String actorUserId,
    required DateTime now,
    String? note,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<Result<RebookingApplied, DeclarationRefusal>> rebookOnto({
    required String operatorId,
    required String departureId,
    required String replacementDepartureId,
    required String actorUserId,
    required DateTime now,
    String? note,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<Map<String, DisruptionRecord>> openFor({
    required String operatorId,
    required DateTime from,
    required DateTime to,
  }) async => throw const ConsoleRequiresDatabase();
}

/// The payout run, without a database.
///
/// Every method refuses. There is no in-memory payout: the amount comes from
/// the ledger's own balances, and a fake ledger that answered with a number
/// would be a number somebody eventually screenshots.
final class UnavailablePayouts implements PayoutDesk {
  const UnavailablePayouts();

  @override
  Future<Result<PayoutRun, PayoutRefusal>> prepare({
    required String operatorId,
    required DateTime from,
    required DateTime to,
    required String actorUserId,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<Result<PayoutRun, PayoutRefusal>> approve({
    required String runId,
    required String actorUserId,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<Result<PayoutRun, PayoutRefusal>> release({
    required String runId,
    required String actorUserId,
    required String reference,
    String? destination,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<List<PayoutRun>> pending({required String actorUserId}) async =>
      throw const ConsoleRequiresDatabase();

  @override
  Future<List<PayoutRun>> statementsFor(String operatorId) async =>
      throw const ConsoleRequiresDatabase();

  @override
  Future<PayoutRun?> statement({
    required String runId,
    String? operatorId,
    String? actorUserId,
  }) async => throw const ConsoleRequiresDatabase();
}

/// The fakes composition, which has no database to mint a link out of
/// (ADR-0026).
///
/// [open] answers null rather than throwing: a link cannot exist in this
/// composition, and "no such link" is the honest answer to somebody holding
/// one — the same answer a revoked or expired token gets.
final class TicketLinksRequireDatabase implements TicketLinks {
  const TicketLinksRequireDatabase();

  @override
  Future<Result<QueuedTicketLink, LinkRefusal>> queueSend({
    required String operatorId,
    required String bookingRef,
    required String channel,
    required String? sendTo,
    required String? byUserId,
    required DateTime now,
  }) async => throw const ConsoleRequiresDatabase();

  @override
  Future<LinkedTicket?> open({
    required String token,
    required DateTime now,
  }) async => null;

  @override
  Future<LinkDestination?> destinationFor(String token) async => null;

  @override
  Future<String?> claim({
    required String token,
    required String userId,
  }) async => null;

  @override
  Future<Result<void, LinkRefusal>> revoke({
    required String operatorId,
    required String bookingRef,
    required DateTime now,
  }) async => throw const ConsoleRequiresDatabase();
}
