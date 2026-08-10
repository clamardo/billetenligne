import 'package:bel_domain/bel_domain.dart';

import '../application/ports/operator_console.dart';
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
