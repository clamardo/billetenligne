import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';

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
    String? preset,
    int? rows,
  }) => _client.saveLayout(name: name, preset: preset, rows: rows);

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
  }) => _client.collectPayment(
    paymentCode: paymentCode,
    stationId: stationId,
  );

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
