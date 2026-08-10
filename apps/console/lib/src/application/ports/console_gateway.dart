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
    String? preset,
    int? rows,
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

  Future<SeatMapDto> seatMap(String departureId);

  Future<CounterSaleDto> collect({
    required String paymentCode,
    required String stationId,
  });

  Future<CounterSaleDto> sell({
    required String departureId,
    required String buyerPhone,
    required List<PassengerDto> passengers,
    required String stationId,
    required String idempotencyKey,
  });
}
