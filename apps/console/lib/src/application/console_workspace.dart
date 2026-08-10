import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';

import 'ports/console_gateway.dart';

/// Which section of the console is open.
///
/// Ordered the way an operator's day is: today's departures first, the till
/// second, and configuration behind both. A fleet manager opens this app
/// twice a month; a vendor opens it every morning.
enum ConsoleSection { today, counter, fleet, network, timetable }

/// Everything the console has loaded, and what it is doing.
///
/// One object rather than a state class per screen. The screens genuinely
/// share data — the timetable editor needs routes and vehicles, the guichet
/// needs today's departures — and threading four loaders through them would
/// mean four chances for two screens to disagree about what the fleet is.
///
/// A plain broadcast stream, like `BookingFlow`: `ChangeNotifier` lives in
/// `package:flutter/foundation` and the layer check refuses Flutter in the
/// application layer.
final class ConsoleWorkspace {
  ConsoleWorkspace({required ConsoleGateway gateway}) : _gateway = gateway;

  final ConsoleGateway _gateway;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  ConsoleIdentityDto? _identity;
  ConsoleIdentityDto? get identity => _identity;

  var _section = ConsoleSection.today;
  ConsoleSection get section => _section;

  var _busy = false;
  bool get busy => _busy;

  ApiFailure? _failure;
  ApiFailure? get failure => _failure;

  /// A one-line confirmation of the last thing that worked — "3 départs
  /// créés". Cleared on the next action, so it never lingers next to
  /// something it does not describe.
  String? _notice;
  String? get notice => _notice;

  List<LayoutDto> layouts = const [];
  List<VehicleDto> vehicles = const [];
  List<RouteDto> routes = const [];
  List<CityDto> cities = const [];
  List<ScheduleDto> schedules = const [];
  List<DepartureBoardDto> board = const [];

  DateTime day = DateTime.now();

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  bool can(String capability) => _identity?.can(capability) ?? false;

  void openSection(ConsoleSection section) {
    _section = section;
    _notice = null;
    _failure = null;
    _emit();
    unawaited(refresh());
  }

  /// Loads who we are and enough of the world to render the current section.
  ///
  /// Identity first and always: the navigation is drawn from capabilities, so
  /// a console that renders before it knows them shows a vendor a Fleet tab
  /// for one frame — and a tab that appears and vanishes reads as a bug.
  Future<void> start() async {
    await _run(() async {
      _identity = await _gateway.identity();
      await _loadSection();
    });
  }

  Future<void> refresh() => _run(_loadSection);

  Future<void> _loadSection() async {
    switch (_section) {
      case ConsoleSection.today:
        board = await _gateway.board(day);
      case ConsoleSection.counter:
        board = await _gateway.board(day);
      case ConsoleSection.fleet:
        layouts = await _gateway.layouts();
        vehicles = await _gateway.vehicles();
      case ConsoleSection.network:
        routes = await _gateway.routes();
        cities = await _gateway.cities();
      case ConsoleSection.timetable:
        schedules = await _gateway.schedules();
        // The editor cannot offer a route or a coach it has not loaded, and
        // loading them lazily would mean an empty dropdown on first open.
        routes = await _gateway.routes();
        vehicles = await _gateway.vehicles();
    }
  }

  void showDay(DateTime date) {
    day = date;
    unawaited(refresh());
  }

  // ── Writes ────────────────────────────────────────────────────────────────

  Future<void> saveLayout({
    required String name,
    required String preset,
    int? rows,
  }) => _run(() async {
    final saved = await _gateway.saveLayout(
      name: name,
      preset: preset,
      rows: rows,
    );
    // Says the version, because saving a name that already exists creates a
    // new one rather than editing — and an operator who expected an edit
    // should find that out here rather than from a support call.
    _notice = saved.version > 1
        ? 'layout.savedVersion|${saved.name}|${saved.version}'
        : 'layout.saved|${saved.name}';
    await _loadSection();
  });

  Future<void> saveVehicle({
    required String registration,
    required String layoutId,
    String? nickname,
  }) => _run(() async {
    await _gateway.saveVehicle(
      registration: registration,
      layoutId: layoutId,
      nickname: nickname,
    );
    _notice = 'vehicle.saved|$registration';
    await _loadSection();
  });

  Future<void> setVehicleStatus({
    required String vehicleId,
    required String status,
  }) => _run(() async {
    final affected = await _gateway.setVehicleStatus(
      vehicleId: vehicleId,
      status: status,
    );
    // Never a bare success. These departures now have no coach, and somebody
    // has to reassign one or declare a disruption before the passengers
    // arrive.
    _notice = affected.isEmpty
        ? 'vehicle.statusChanged'
        : 'vehicle.statusAffects|${affected.length}';
    await _loadSection();
  });

  Future<void> saveRoute({
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
  }) => _run(() async {
    await _gateway.saveRoute(
      code: code,
      originCity: originCity,
      destinationCity: destinationCity,
      durationMinutes: durationMinutes,
    );
    _notice = 'route.saved|$code';
    await _loadSection();
  });

  Future<void> saveSchedule({
    required String routeId,
    required String rrule,
    required String departureTime,
    required int fareMinor,
    required DateTime validFrom,
    String? vehicleId,
  }) => _run(() async {
    await _gateway.saveSchedule(
      routeId: routeId,
      rrule: rrule,
      departureTime: departureTime,
      fareMinor: fareMinor,
      validFrom: validFrom,
      vehicleId: vehicleId,
    );
    _notice = 'schedule.saved';
    await _loadSection();
  });

  /// Publishes a timetable as departures a traveller can buy.
  Future<void> materialise({
    required String scheduleId,
    required DateTime from,
    required DateTime to,
  }) => _run(() async {
    final report = await _gateway.materialise(
      scheduleId: scheduleId,
      from: from,
      to: to,
    );

    // Three genuinely different outcomes, and collapsing them into "done"
    // would hide the two that need acting on: nothing new (you already
    // published this), and dates that could not be filled (that coach is in
    // the workshop, so those days are not on sale).
    if (report.skipped.isNotEmpty) {
      _notice = 'materialise.skipped|${report.created}|'
          '${report.skipped.length}|${report.skipped.first.reason}';
    } else if (report.created == 0) {
      _notice = 'materialise.nothingNew|${report.alreadyExisted}';
    } else {
      _notice = 'materialise.created|${report.created}';
    }
    await _loadSection();
  });

  Future<ManifestDto?> manifest(String departureId) async {
    ManifestDto? manifest;
    await _run(() async => manifest = await _gateway.manifest(departureId));
    return manifest;
  }

  Future<SeatMapDto?> seatMap(String departureId) async {
    SeatMapDto? map;
    await _run(() async => map = await _gateway.seatMap(departureId));
    return map;
  }

  Future<CounterSaleDto?> collect({
    required String paymentCode,
    required String stationId,
  }) async {
    CounterSaleDto? sale;
    await _run(() async {
      sale = await _gateway.collect(
        paymentCode: paymentCode,
        stationId: stationId,
      );
      _notice = 'counter.collected|${sale!.ref}';
    });
    return sale;
  }

  Future<CounterSaleDto?> sell({
    required String departureId,
    required String buyerPhone,
    required List<PassengerDto> passengers,
    required String stationId,
    required String idempotencyKey,
  }) async {
    CounterSaleDto? sale;
    await _run(() async {
      sale = await _gateway.sell(
        departureId: departureId,
        buyerPhone: buyerPhone,
        passengers: passengers,
        stationId: stationId,
        idempotencyKey: idempotencyKey,
      );
      _notice = 'counter.sold|${sale!.ref}';
    });
    return sale;
  }

  /// Runs work with one busy flag and one failure slot.
  ///
  /// The failure is cleared at the start rather than at the end: a screen
  /// showing yesterday's error beside today's spinner is a screen nobody
  /// believes.
  Future<void> _run(Future<void> Function() work) async {
    _busy = true;
    _failure = null;
    _emit();
    try {
      await work();
    } on ApiFailure catch (failure) {
      _failure = failure;
      _notice = null;
    } finally {
      _busy = false;
      _emit();
    }
  }

  Future<void> dispose() => _changes.close();
}
