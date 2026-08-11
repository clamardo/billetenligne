import 'dart:async';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/console_gateway.dart';
import 'ports/file_picker.dart';
import 'ports/file_saver.dart';

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
  finance,
  protection,
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
  ConsoleWorkspace({
    required ConsoleGateway gateway,
    FilePicker? files,
    FileSaver? downloads,
  }) : _gateway = gateway,
       _files = files,
       _downloads = downloads;

  final ConsoleGateway _gateway;

  /// Null when there is nowhere to pick a file from — a widget test, or any
  /// build that is not the browser. The vitrine screen hides the upload
  /// control rather than offering one that cannot open anything.
  final FilePicker? _files;

  /// Null outside the browser, like [_files]. The statements screen hides the
  /// download rather than offering a button that cannot hand anybody a file.
  final FileSaver? _downloads;

  bool get canUploadAssets => _files != null;
  bool get canDownloadStatements => _downloads != null;
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

  /// The weekly statements, newest first. Read-only everywhere: the party
  /// being paid does not get to move the row that pays them, and the server
  /// enforces that with a grant rather than with a missing button.
  List<PayoutRunDto> statements = const [];

  /// Standing protection agreements, in either role (`08-disruption.md` §5).
  ///
  /// Loaded for the whole console rather than only its own section, because
  /// the dispatcher's disruption sheet has to know whether option ③ exists
  /// at all — a rescue plan that omits an agreement the operator is paying
  /// for is a plan that sends people home.
  List<ProtectionAgreementDto> agreements = const [];

  /// Agreements somebody else has proposed and we have not answered. The
  /// number on the tab, because a proposal nobody notices is a proposal that
  /// expires unanswered.
  int get agreementsAwaitingUs => agreements.where((a) => a.awaitingUs).length;

  /// Protection requests in either direction (`08-disruption.md` §2.3).
  ///
  /// One list, not an inbox and an outbox. The same row is the one we are
  /// waiting on and the one they are waiting on, and two lists fetched
  /// separately would show it decided in one and pending in the other for as
  /// long as the two calls were apart.
  List<ProtectionRequestDto> requests = const [];

  /// Requests another company is waiting on us to answer. The number on the
  /// tab: somebody is standing at a gare while this sits unread.
  int get requestsAwaitingUs => requests.where((r) => r.awaitingUs).length;

  /// Whether option ③ exists at all this morning — an agreement in force,
  /// with room left under its ceiling.
  ///
  /// Asked by the disruption sheet before it draws the option, because
  /// offering a dispatcher a rescue that will be refused at 05:40 is worse
  /// than not offering it.
  bool get canAskForProtection => agreements.any((a) => a.isLive);

  /// The operator's storefront. Null until the vitrine section is opened —
  /// nothing else on the console needs it, and loading it on every start
  /// would be a request per morning for a screen most people open twice.
  VitrineDto? vitrine;

  DateTime day = DateTime.now();

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  bool can(String capability) => _identity?.can(capability) ?? false;

  /// Whether this person's console has anything to do with protection at all.
  ///
  /// A vendor at a counter neither negotiates agreements nor answers a
  /// roadside request, and loading two lists they will never see would be two
  /// requests every morning on a connection that is paid for by the megabyte.
  bool get _canSeeProtection =>
      can('protection.manage') || can('disruption.declare');

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
        // The disruption sheet is opened from this screen, and it has to know
        // whether asking another company is even possible before it draws the
        // option (§2.2 ③). Loaded here rather than lazily inside the sheet: a
        // dispatcher at the roadside opens it once, on 2G, and an option that
        // appears three seconds later is one they have already decided
        // without.
        if (_canSeeProtection) {
          agreements = await _gateway.protectionAgreements();
          requests = await _gateway.protectionRequests();
        }
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
      case ConsoleSection.finance:
        statements = await _gateway.statements();
      case ConsoleSection.protection:
        agreements = await _gateway.protectionAgreements();
        requests = await _gateway.protectionRequests();
        // The corridors offered when proposing are built from the lines this
        // operator actually runs. Loading them lazily would mean an empty
        // list the first time the dialog opens, which reads as "we serve
        // nowhere" rather than "not loaded yet".
        routes = await _gateway.routes();
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
    ChangePolicy change = ChangePolicy.standard,
  }) => _run(() async {
    if (name.trim().isEmpty || !policy.isWellFormed || !change.isWellFormed) {
      _notice = 'policy.invalid';
      return;
    }
    final saved = await _gateway.saveRefundPolicy(
      name: name.trim(),
      policy: policy,
      change: change,
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

  /// Declares a disruption, and says what it did.
  ///
  /// Never a bare success. "Signalé" tells a dispatcher nothing; the count of
  /// passengers told is what tells them the message went out and how much of
  /// their morning just changed — and whether the declaration entitled those
  /// passengers to a free exchange, which decides who they are about to talk
  /// to at the counter.
  Future<void> declareDisruption({
    required String departureId,
    required DisruptionKind kind,
    required DisruptionCause cause,
    String? note,
    DateTime? revisedDepartsAt,
  }) => _run(() async {
    final declared = await _gateway.declareDisruption(
      departureId: departureId,
      request: DeclareDisruptionRequest(
        kind: kind,
        cause: cause,
        note: note,
        revisedDepartsAt: revisedDepartsAt,
      ),
    );
    _notice = declared.disruption.marksInvoluntary
        ? 'disruption.declaredFree|${declared.bookingsAffected}'
        : 'disruption.declared|${declared.bookingsAffected}';
    await _loadSection();
  });

  /// This operator's own later departures on the same road, with room.
  ///
  /// Read off the board that is already loaded rather than fetched: the
  /// dispatcher is looking at today, the candidates are on today, and a round
  /// trip here would be one more thing to wait for at a roadside. The rules
  /// are the domain's, so the sheet cannot offer a departure the server is
  /// about to refuse.
  List<DepartureBoardDto> replacementsFor(DepartureBoardDto broken) => [
    for (final row in board)
      if (row.id != broken.id &&
          row.routeCode == broken.routeCode &&
          row.departsAt.isAfter(broken.departsAt) &&
          sellableDepartureStatuses.contains(row.status) &&
          row.available > 0)
        row,
  ];

  /// Option ③ of `08-disruption.md` §2.2: somebody else's coach.
  ///
  /// Asked at the moment the dispatcher opens the sheet, never held warm — a
  /// competitor's free-seat count ten minutes old is a rescue that fails at
  /// the door. The list is narrowed here rather than on the server because
  /// the narrowing is a *console* judgement: the public search answers "who
  /// is going to Pointe-Noire this afternoon", and what a dispatcher can act
  /// on is the subset that is somebody else's, later, has room, and is
  /// covered by an agreement in force.
  ///
  /// An empty list is a real answer and the sheet says so plainly. Offering a
  /// coach the server will refuse teaches people that our buttons lie.
  Future<List<DepartureSummaryDto>> protectionCandidates(
    DepartureBoardDto broken,
  ) async {
    // The board carries a route *code*; the public search needs two cities.
    // Fetched here rather than with the morning's board, because most
    // mornings nobody breaks down — and this is the one screen where the
    // extra request buys something rather than costing it.
    if (routes.isEmpty) routes = await _gateway.routes();

    final route = routes.where((r) => r.code == broken.routeCode).firstOrNull;
    if (route == null) return const [];

    final covering = [
      for (final agreement in agreements)
        if (agreement.isLive &&
            agreement.covers(route.originCity, route.destinationCity))
          agreement.counterpartyId,
    ];
    if (covering.isEmpty) return const [];

    final trips = await _gateway.tripsOn(
      originCity: route.originCity,
      destinationCity: route.destinationCity,
      date: broken.departsAt,
    );

    return [
      for (final trip in trips)
        if (covering.contains(trip.operatorId) &&
            trip.departsAt.isAfter(broken.departsAt) &&
            trip.seatsAvailable > 0)
          trip,
    ]..sort((a, b) => a.departsAt.compareTo(b.departsAt));
  }

  /// Option ② of ADR-0016 §2.2: the operator's own next departure.
  ///
  /// Partial coverage is a success and is said as a number. "18 sur 42" is
  /// what a dispatcher acts on next; a notice that said only "réacheminés"
  /// would hide the twenty-four still standing at the roadside.
  Future<void> rebookOnto({
    required String departureId,
    required String replacementDepartureId,
    String? note,
  }) => _run(() async {
    final applied = await _gateway.rebookOnto(
      departureId: departureId,
      request: RebookRequest(
        replacementDepartureId: replacementDepartureId,
        note: note,
      ),
    );
    _notice = applied.coversEverybody
        ? 'rebook.applied|${applied.passengersMoved}'
        : 'rebook.partial|${applied.passengersMoved}|${applied.passengersLeft}';
    await _loadSection();
  });

  /// The coaches that could be sent out to a stranded departure.
  ///
  /// Loaded on demand rather than kept warm: the today screen has no other
  /// reason to hold the fleet, and a dispatcher looking for a spare is doing
  /// it once, at a moment when a stale list is worse than a round trip. Only
  /// sellable ones — a coach in maintenance is not a rescue, and offering it
  /// here would be offering a swap the server is going to refuse.
  Future<List<VehicleDto>> spareCoaches({String? excluding}) async {
    var spares = const <VehicleDto>[];
    await _run(() async {
      vehicles = await _gateway.vehicles();
      spares = [
        for (final v in vehicles)
          if (v.sellable && v.registration != excluding) v,
      ];
    });
    return spares;
  }

  /// Option ① of ADR-0016 §2.2: a different coach, the same journey.
  ///
  /// Never a bare success. What a dispatcher needs to hear back is how many
  /// people are now sitting somewhere else — that is the number they are
  /// about to be asked about at the door — and whether anybody mid-checkout
  /// lost their seat to the swap.
  Future<void> assignRescueCoach({
    required String departureId,
    required String vehicleId,
    String? note,
  }) => _run(() async {
    final applied = await _gateway.assignRescueCoach(
      departureId: departureId,
      request: RescueCoachRequest(vehicleId: vehicleId, note: note),
    );
    // `moved`, not `moves.length`: the moves carry every passenger on the
    // coach, including the ones whose seat number did not change. Reporting
    // the list length would tell a dispatcher forty-two people moved when
    // nobody did.
    _notice = applied.moved == 0
        ? 'rescue.appliedSameSeats|${applied.registration}'
        : 'rescue.applied|${applied.registration}|${applied.moved}';
    await _loadSection();
  });

  /// Write the terms and send them to the other company (`08-disruption.md`
  /// §5).
  ///
  /// The notice says *proposed*, never *agreed*. An operator who reads
  /// "accord créé" and stops thinking about it is one who finds out at the
  /// roadside that nobody ever accepted.
  Future<void> proposeAgreement({
    required String counterpartyCode,
    required List<String> corridors,
    bool reciprocal = true,
    int rebillDiscountBps = 0,
    int? monthlyCapSeats,
    int? autoAcceptWhenSpareAbove,
  }) => _run(() async {
    if (corridors.isEmpty) {
      _notice = 'protection.noCorridors';
      return;
    }
    final proposed = await _gateway.proposeAgreement(
      ProposeAgreementRequest(
        counterpartyCode: counterpartyCode,
        corridors: corridors,
        reciprocal: reciprocal,
        rebillDiscountBps: rebillDiscountBps,
        monthlyCapSeats: monthlyCapSeats,
        autoAcceptWhenSpareAbove: autoAcceptWhenSpareAbove,
      ),
    );
    _notice = 'protection.proposed|${proposed.counterpartyName}';
    await _loadSection();
  });

  Future<void> decideAgreement({
    required String agreementId,
    required String decision,
    String? reason,
  }) => _run(() async {
    final decided = await _gateway.decideAgreement(
      agreementId: agreementId,
      request: AgreementDecisionRequest(decision: decision, reason: reason),
    );
    _notice = 'protection.$decision|${decided.counterpartyName}';
    await _loadSection();
  });

  /// Ask another company for room (`08-disruption.md` §2.2 option ③).
  ///
  /// Nothing moves here: the request lands on the other console and waits.
  /// The notice says so, because a dispatcher who reads "envoyé" and walks
  /// away is one who never finds out that nobody answered.
  Future<void> askForProtection({
    required String departureId,
    required String replacementDepartureId,
    String? note,
  }) => _run(() async {
    final asked = await _gateway.askForProtection(
      ProtectionRequestBody(
        departureId: departureId,
        replacementDepartureId: replacementDepartureId,
        note: note,
      ),
    );
    _notice =
        'protection.asked|${asked.counterpartyName}|${asked.seatsRequested}';
    await _loadSection();
  });

  /// `accept` or `decline`, by the company being asked.
  ///
  /// Accepting moves the passengers in the same call, so the notice is about
  /// people and not about a record: how many travel with the other company
  /// now, and — when the coach could not take everybody — how many are still
  /// standing there. Partial coverage is a success and is said as a number.
  Future<void> decideProtectionRequest({
    required String requestId,
    required String decision,
    String? reason,
  }) => _run(() async {
    final decided = await _gateway.decideProtectionRequest(
      requestId: requestId,
      request: AgreementDecisionRequest(decision: decision, reason: reason),
    );
    if (decision == 'decline') {
      _notice = 'protection.requestDeclined|${decided.counterpartyName}';
    } else if (decided.coversEverybody) {
      _notice =
          'protection.moved|${decided.seatsMoved ?? 0}'
          '|${decided.counterpartyName}';
    } else {
      _notice =
          'protection.movedPartial|${decided.seatsMoved ?? 0}'
          '|${decided.seatsRequested}|${decided.counterpartyName}';
    }
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

  /// Downloads one statement as the document `04-payments.md` §6.2 calls for.
  ///
  /// The bytes come down through the authenticated client and are handed to
  /// the browser here, because the route needs a bearer token and a plain
  /// link sends no headers. The **server names the file** — the name is part
  /// of a commercial document, and one composed on the client would differ
  /// from the one the back office produces for the same run.
  Future<void> downloadStatement(String runId) async {
    final saver = _downloads;
    if (saver == null) return;

    await _run(() async {
      final file = await _gateway.statementPdf(runId);
      await saver.save(
        filename: file.filename,
        bytes: file.bytes,
        mimeType: file.mimeType,
      );
      _notice = 'statement.downloaded|${file.filename}';
    });
  }

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

  /// What cancelling this booking would give back. A read, and nothing else:
  /// the vendor says the number out loud before anybody agrees to anything.
  Future<RefundOfferDto?> quoteRefund(String bookingRef) async {
    RefundOfferDto? offer;
    await _run(() async {
      offer = await _gateway.refundOffer(bookingRef.trim());
    });
    return offer;
  }

  Future<IssuedRefundDto?> refund({
    required String bookingRef,
    required String reason,
  }) async {
    IssuedRefundDto? issued;
    await _run(() async {
      issued = await _gateway.refundBooking(
        bookingRef: bookingRef.trim(),
        reason: reason.trim(),
      );
      _notice = 'refund.issued|${issued!.bookingRef}';
    });
    return issued;
  }

  Future<ClaimedRefundDto?> payClaim({
    required String claimCode,
    required String stationId,
  }) async {
    ClaimedRefundDto? claimed;
    await _run(() async {
      claimed = await _gateway.claimRefund(
        claimCode: claimCode.trim(),
        stationId: stationId,
      );
      _notice = 'refund.paid|${claimed!.bookingRef}';
    });
    return claimed;
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
