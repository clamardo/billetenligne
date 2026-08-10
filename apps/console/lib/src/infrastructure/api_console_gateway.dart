import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/console_gateway.dart';

/// The real gateway: the shared typed client, nothing more.
///
/// Thin on purpose, exactly like `ApiTravelGateway`. Retries, idempotency
/// headers, trace ids and the offline taxonomy live in `bel_client`, where
/// the traveller app already gets them — duplicating any of it here is how
/// two surfaces end up with two answers to one dropped connection.
final class ApiConsoleGateway implements ConsoleGateway {
  const ApiConsoleGateway(this._client);

  final BelApiClient _client;

  @override
  Future<ConsoleIdentityDto> identity() => _client.consoleIdentity();

  @override
  Future<List<LayoutDto>> layouts() => _client.layouts();

  @override
  Future<LayoutDto> saveLayout({
    required String name,
    required String preset,
    int? rows,
  }) => _client.saveLayout(name: name, preset: preset, rows: rows);

  @override
  Future<LayoutDto> drawLayout(LayoutDraft draft) => _client.drawLayout(draft);

  @override
  Future<RefundOfferDto> refundOffer(String bookingRef) =>
      _client.refundOffer(bookingRef);

  @override
  Future<IssuedRefundDto> refundBooking({
    required String bookingRef,
    required String reason,
  }) => _client.refundBooking(bookingRef: bookingRef, reason: reason);

  @override
  Future<ClaimedRefundDto> claimRefund({
    required String claimCode,
    required String stationId,
  }) => _client.claimRefund(claimCode: claimCode, stationId: stationId);

  @override
  Future<({List<RefundPolicyDto> items, bool hasDefault})> refundPolicies() =>
      _client.refundPolicies();

  @override
  Future<RefundPolicyDto> saveRefundPolicy({
    required String name,
    required RefundPolicy policy,
  }) => _client.saveRefundPolicy(name: name, policy: policy);

  @override
  Future<RefundPolicyDto?> setDefaultRefundPolicy({
    String? policyId,
    int? version,
  }) => _client.setDefaultRefundPolicy(policyId: policyId, version: version);

  @override
  Future<List<VehicleDto>> vehicles() => _client.vehicles();

  @override
  Future<VehicleDto> saveVehicle({
    required String registration,
    required String layoutId,
    String? nickname,
    String? model,
  }) => _client.saveVehicle(
    registration: registration,
    layoutId: layoutId,
    nickname: nickname,
    model: model,
  );

  @override
  Future<List<String>> setVehicleStatus({
    required String vehicleId,
    required String status,
  }) => _client.setVehicleStatus(vehicleId: vehicleId, status: status);

  @override
  Future<List<RouteDto>> routes() => _client.operatorRoutes();

  @override
  Future<RouteDto> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
  }) => _client.saveRoute(
    code: code,
    originCity: originCity,
    destinationCity: destinationCity,
    durationMinutes: durationMinutes,
  );

  /// The same public endpoint the traveller app reads. An operator picks
  /// endpoints from the cities the platform serves, not from free text — a
  /// typed city code is a route nobody can search for.
  @override
  Future<List<CityDto>> cities() => _client.cities();

  @override
  Future<List<ScheduleDto>> schedules() => _client.schedules();

  @override
  Future<ScheduleDto> saveSchedule({
    required String routeId,
    required String rrule,
    required String departureTime,
    required int fareMinor,
    required DateTime validFrom,
    String? vehicleId,
    DateTime? validUntil,
  }) => _client.saveSchedule(
    routeId: routeId,
    rrule: rrule,
    departureTime: departureTime,
    fareMinor: fareMinor,
    validFrom: validFrom,
    vehicleId: vehicleId,
    validUntil: validUntil,
  );

  @override
  Future<MaterialisationDto> materialise({
    required String scheduleId,
    required DateTime from,
    required DateTime to,
  }) => _client.materialise(scheduleId: scheduleId, from: from, to: to);

  @override
  Future<List<DepartureBoardDto>> board(DateTime localDate) =>
      _client.departureBoard(localDate);

  @override
  Future<ManifestDto> manifest(String departureId) =>
      _client.manifest(departureId);

  @override
  Future<SeatMapDto> seatMap(String departureId) =>
      _client.seatMap(departureId);

  @override
  Future<CounterSaleDto> collect({
    required String paymentCode,
    required String stationId,
  }) => _client.collectPayment(paymentCode: paymentCode, stationId: stationId);

  @override
  Future<VitrineDto> vitrine() => _client.vitrine();

  @override
  Future<VitrineDto> saveVitrine(SaveVitrineRequest request) =>
      _client.saveVitrine(request);

  @override
  Future<VitrineDto> uploadVitrineAsset({
    required String asset,
    required List<int> bytes,
    required String mimeType,
  }) => _client.uploadVitrineAsset(
    asset: asset,
    bytes: bytes,
    // The browser's guess, or `application/octet-stream` when it has none —
    // a blank Content-Type makes some proxies drop the body. The server
    // sniffs the bytes either way.
    contentType: mimeType.isEmpty ? 'application/octet-stream' : mimeType,
  );

  @override
  Future<VitrineDto> removeVitrineAsset(String asset) =>
      _client.removeVitrineAsset(asset);

  @override
  Future<CounterSaleDto> sell({
    required String departureId,
    required String buyerPhone,
    required List<PassengerDto> passengers,
    required String stationId,
    required String idempotencyKey,
  }) => _client.sellAtCounter(
    departureId: departureId,
    buyerPhone: buyerPhone,
    passengers: passengers,
    stationId: stationId,
    idempotencyKey: idempotencyKey,
  );
}
