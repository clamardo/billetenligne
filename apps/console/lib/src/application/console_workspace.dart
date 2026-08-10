import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/console_gateway.dart';
import 'ports/file_picker.dart';

/// Which section of the console is open.
///
/// Ordered the way an operator's day is: today's departures first, the till
/// second, and configuration behind both. A fleet manager opens this app
/// twice a month; a vendor opens it every morning.
enum ConsoleSection {
  today,
  counter,
  fleet,
  network,
  timetable,
  policies,
  vitrine,
}

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
  ConsoleWorkspace({required ConsoleGateway gateway, FilePicker? files})
    : _gateway = gateway,
      _files = files;

  final ConsoleGateway _gateway;

  /// Null when there is nowhere to pick a file from — a widget test, or any
  /// build that is not the browser. The vitrine screen hides the upload
  /// control rather than offering one that cannot open anything.
  final FilePicker? _files;

  bool get canUploadAssets => _files != null;
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

  /// Every version of every refund policy, newest of each first.
  ///
  /// Old versions stay in the list rather than being hidden, because a
  /// booking sold last March is judged by the policy as it stood last March
  /// (ADR-0015 rule 1) — and the person answering a question about that
  /// booking needs to be able to read the terms it was actually sold under.
  List<RefundPolicyDto> policies = const [];

  /// Whether new sales carry any policy at all. Said out loud rather than
  /// inferred from the list, because "no default" is a real state with a real
  /// consequence: those bookings have no self-service refund.
  bool hasDefaultPolicy = false;

  /// The operator's storefront. Null until the vitrine section is opened —
  /// nothing else on the console needs it, and loading it on every start
  /// would be a request per morning for a screen most people open twice.
  VitrineDto? vitrine;

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
      case ConsoleSection.policies:
        final loaded = await _gateway.refundPolicies();
        policies = loaded.items;
        hasDefaultPolicy = loaded.hasDefault;
      case ConsoleSection.vitrine:
        vitrine = await _gateway.vitrine();
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

  /// Saves a layout drawn section by section.
  ///
  /// Refuses locally first. The server refuses the same layout for the same
  /// reasons, but an operator who has just spent twenty minutes drawing a
  /// coach should not learn about a bad row count from a round trip.
  Future<void> drawLayout(LayoutDraft draft) => _run(() async {
    if (!draft.isValid) {
      _notice = 'layout.invalid';
      return;
    }
    final saved = await _gateway.drawLayout(draft);
    _notice = saved.version > 1
        ? 'layout.savedVersion|${saved.name}|${saved.version}'
        : 'layout.saved|${saved.name}';
    await _loadSection();
  });

  /// Writes a policy, or the next version of one with this name.
  ///
  /// Never an edit, and the screen says so before the button is pressed:
  /// bookings already sold keep the version stamped on them, which is the
  /// whole point of versioning (ADR-0015 rule 1).
  Future<void> saveRefundPolicy({
    required String name,
    required RefundPolicy policy,
  }) => _run(() async {
    if (name.trim().isEmpty || !policy.isWellFormed) {
      _notice = 'policy.invalid';
      return;
    }
    final saved = await _gateway.saveRefundPolicy(
      name: name.trim(),
      policy: policy,
    );
    _notice = saved.version > 1
        ? 'policy.savedVersion|${saved.name}|${saved.version}'
        : 'policy.saved|${saved.name}';
    await _loadSection();
  });

  /// Points future sales at one version, or at nothing.
  Future<void> setDefaultPolicy({String? policyId, int? version}) =>
      _run(() async {
        final saved = await _gateway.setDefaultRefundPolicy(
          policyId: policyId,
          version: version,
        );
        _notice = saved == null
            ? 'policy.defaultCleared'
            : 'policy.defaultSet|${saved.name}|${saved.version}';
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
      _notice =
          'materialise.skipped|${report.created}|'
          '${report.skipped.length}|${report.skipped.first.reason}';
    } else if (report.created == 0) {
      _notice = 'materialise.nothingNew|${report.alreadyExisted}';
    } else {
      _notice = 'materialise.created|${report.created}';
    }
    await _loadSection();
  });

  /// Saves the storefront.
  ///
  /// The notice repeats the title rather than saying "saved", for the same
  /// reason the layout notice repeats the version: this is the name a
  /// traveller will see, and a confirmation that shows it is a confirmation
  /// somebody can catch a typo in.
  Future<void> saveVitrine(SaveVitrineRequest request) => _run(() async {
    final saved = await _gateway.saveVitrine(request);
    vitrine = saved;
    _notice = 'vitrine.saved|${saved.titleFor('fr')}';
  });

  /// Asks for a file and sends it.
  ///
  /// A dismissed dialog is not an error and not a busy spinner: the common
  /// outcome of opening a file picker is closing it again, and a screen that
  /// showed a failure for that would be wrong more often than right.
  Future<void> uploadVitrineAsset(String asset) async {
    final picker = _files;
    if (picker == null) return;

    final file = await picker.pick(
      accept: const ['image/png', 'image/jpeg', 'image/svg+xml'],
    );
    if (file == null) return;

    await _run(() async {
      vitrine = await _gateway.uploadVitrineAsset(
        asset: asset,
        bytes: file.bytes,
        mimeType: file.mimeType,
      );
      _notice = 'vitrine.assetSaved|$asset';
    });
  }

  Future<void> removeVitrineAsset(String asset) => _run(() async {
    vitrine = await _gateway.removeVitrineAsset(asset);
    _notice = 'vitrine.assetRemoved|$asset';
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
