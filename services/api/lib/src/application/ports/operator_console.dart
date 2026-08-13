import 'package:bel_domain/bel_domain.dart';

/// A seat layout template, as the console lists it.
final class LayoutSummary {
  const LayoutSummary({
    required this.id,
    required this.name,
    required this.version,
    required this.capacity,
    required this.mode,
    required this.vehicleCount,
  });

  final String id;
  final String name;
  final int version;
  final int capacity;
  final String mode;

  /// How many coaches use this template. Shown because editing one that is in
  /// use creates a new version rather than changing what is already sold, and
  /// an operator should see the blast radius before they start.
  final int vehicleCount;
}

final class VehicleSummary {
  const VehicleSummary({
    required this.id,
    required this.registration,
    required this.layoutId,
    required this.layoutName,
    required this.capacity,
    required this.status,
    this.nickname,
    this.model,
    this.amenities = const [],
  });

  final String id;
  final String registration;
  final String layoutId;
  final String layoutName;
  final int capacity;

  /// `active` | `maintenance` | `out_of_service` | `blocked_compliance`.
  final String status;

  final String? nickname;
  final String? model;
  final List<String> amenities;

  bool get isSellable => status == 'active';
}

final class RouteSummary {
  const RouteSummary({
    required this.id,
    required this.code,
    required this.originCity,
    required this.destinationCity,
    required this.durationMinutes,
    required this.active,
    this.stops = const [],
    this.stopStationNames = const {},
    this.segments = SegmentPricing.empty,
  });

  final String id;
  final String code;
  final String originCity;
  final String destinationCity;
  final int durationMinutes;
  final bool active;

  /// Where the coach stops on the way, in order. Empty for most roads in this
  /// market, which is why it is defaulted rather than required.
  final List<RouteStop> stops;

  /// Station id to name, for the stops that named a yard. Resolved by the
  /// adapter rather than by the handler, because it is one join and the
  /// alternative is a request per stop.
  final Map<String, String> stopStationNames;

  /// The pieces of this road the operator has put a price on (ADR-0025).
  /// Empty is the ordinary case and means the road sells end to end only.
  final SegmentPricing segments;
}

/// A place a coach actually leaves from.
///
/// Not a city — a yard, with a name people use and directions they need. In
/// Brazzaville "la gare de Mikalou" and "le terminus de Kinsoundi" are forty
/// minutes apart by taxi at six in the morning, and a ticket that says only
/// "Brazzaville" is a ticket somebody misses their coach over.
///
/// [boardingNotes] is where the operator writes what a map cannot: *entrée
/// par la rue derrière la station Total, guichet 3*. It is printed under the
/// name on the ticket rather than kept in an agency's head.
final class StationSummary {
  const StationSummary({
    required this.id,
    required this.cityCode,
    required this.name,
    required this.active,
    this.lat,
    this.lng,
    this.boardingNotes,
  });

  final String id;
  final String cityCode;
  final String name;

  /// A closed terminal is deactivated, never deleted: departures sold last
  /// month still have to say where their passengers were told to stand.
  final bool active;

  final double? lat;
  final double? lng;
  final String? boardingNotes;
}

final class PatternSummary {
  const PatternSummary({
    required this.id,
    required this.routeId,
    required this.routeCode,
    required this.recurrence,
    required this.departureTime,
    required this.fare,
    required this.validFrom,
    required this.active,
    this.vehicleId,
    this.validUntil,
  });

  final String id;
  final String routeId;
  final String routeCode;
  final Recurrence recurrence;

  /// Local time of day, `HH:mm`. Not an instant — "the 06:00" is a local fact
  /// about a timetable, and storing it as UTC puts it on the wrong hour the
  /// day anything about the offset changes.
  final String departureTime;

  final Money fare;
  final DateTime validFrom;
  final DateTime? validUntil;
  final bool active;
  final String? vehicleId;
}

/// What materialising a timetable actually did.
final class MaterialisationReport {
  const MaterialisationReport({
    required this.created,
    required this.alreadyExisted,
    required this.skipped,
  });

  final int created;

  /// Re-running over a range that was already materialised is a **no-op**, not
  /// a duplicate. A dispatcher who taps twice must not sell the same coach
  /// twice, and the honest way to say that is to report it rather than to
  /// silently do nothing.
  final int alreadyExisted;

  /// Dates the rule matched but nothing could be created for — no vehicle
  /// assigned, or the assigned one is in the workshop. Named rather than
  /// dropped: a silently missing Thursday is a coach nobody can book.
  final List<({DateTime date, String reason})> skipped;
}

/// A passenger on a manifest.
final class ManifestRow {
  const ManifestRow({
    required this.seatLabel,
    required this.passengerName,
    required this.bookingRef,
    required this.boarded,
    this.passengerPhone,
    this.boardedAt,
    this.boardsAt,
    this.alightsAt,
  });

  final String seatLabel;
  final String passengerName;
  final String bookingRef;
  final bool boarded;
  final String? passengerPhone;
  final DateTime? boardedAt;

  /// The towns this passenger gets on and off at, when they bought a piece of
  /// the road rather than all of it (ADR-0025). Null is the whole journey.
  final String? boardsAt;
  final String? alightsAt;
}

final class Manifest {
  const Manifest({
    required this.departureId,
    required this.routeCode,
    required this.departsAt,
    required this.capacity,
    required this.rows,
  });

  final String departureId;
  final String routeCode;
  final DateTime departsAt;
  final int capacity;
  final List<ManifestRow> rows;

  int get sold => rows.length;
  int get boarded => rows.where((r) => r.boarded).length;
}

/// The pinned departure a scanner boards from (ADR-0022).
///
/// Downloaded once, in the yard, on whatever signal there is. After that the
/// door works with no network at all, which is the whole design: the verdict
/// is a signature check, a lookup in [tickets] and the device's own
/// redemption log.
final class BoardingManifestData {
  const BoardingManifestData({
    required this.departureId,
    required this.operatorCode,
    required this.routeCode,
    required this.departsAt,
    required this.tickets,
    required this.voided,
    required this.capacity,
  });

  final String departureId;
  final String operatorCode;
  final String routeCode;
  final DateTime departsAt;
  final int capacity;

  /// Live tickets, one per seat.
  final List<BoardingTicket> tickets;

  /// `REF/SEAT` for every ticket voided since it was issued — refunded,
  /// cancelled, or moved to another coach. Carried explicitly because an
  /// Ed25519 signature stays valid forever: only the manifest knows the money
  /// went back, and a device that never hears about it boards somebody who
  /// has already been paid.
  final List<String> voided;
}

/// One seat on a pinned manifest.
final class BoardingTicket {
  const BoardingTicket({
    required this.bookingRef,
    required this.seatLabel,
    required this.passengerName,
    required this.rotatingSecret,
    this.boardsAt,
    this.alightsAt,
  });

  final String bookingRef;
  final String seatLabel;
  final String passengerName;

  /// Seeds the freshness code the traveller's screen regenerates every thirty
  /// seconds (ADR-0007). It is what makes a screenshot detectably stale, and
  /// it is why this response is a credential rather than a list.
  final List<int> rotatingSecret;

  /// Where this passenger gets on and off, when they bought a piece of the
  /// road (ADR-0025). Null is the whole journey.
  final String? boardsAt;
  final String? alightsAt;
}

/// Everything an operator configures and runs.
///
/// One port for the whole console surface, unlike the traveller side where
/// `TravelGateway` and `IdentityGateway` are separate. The reason is the same
/// one that split those: these calls are one conversation. Creating a layout
/// leads to a vehicle leads to a route leads to a timetable leads to
/// departures, and every screen in the console is a step in it.
///
/// Every method takes a [TenantScope]-derived operator id. There is no method
/// here that can be called without one, which is what makes "did we remember
/// to filter by tenant?" a question the compiler asks (ADR-0011 defence #3).
abstract interface class OperatorConsole {
  // ── Fleet ─────────────────────────────────────────────────────────────────

  Future<List<LayoutSummary>> layouts(String operatorId);

  /// Creates a layout, or a **new version** of one that already has this name.
  ///
  /// Versioning rather than editing, for the same reason refund policies are
  /// versioned (ADR-0015): a departure keeps the layout it was sold with, so
  /// changing a template can never renumber a seat somebody already bought.
  Future<LayoutSummary> saveLayout({
    required String operatorId,
    required String name,
    required SeatLayout layout,
  });

  Future<List<VehicleSummary>> vehicles(String operatorId);

  Future<VehicleSummary?> saveVehicle({
    required String operatorId,
    required String registration,
    required String layoutId,
    String? id,
    String? nickname,
    String? model,
    List<String> amenities,
  });

  /// Anything but `active` immediately surfaces the future departures it
  /// affects. It never silently drops bookings — that is the whole reason this
  /// returns the list rather than a bare success.
  Future<List<String>> setVehicleStatus({
    required String operatorId,
    required String vehicleId,
    required String status,
  });

  // ── Network ───────────────────────────────────────────────────────────────

  Future<List<RouteSummary>> routes(String operatorId);

  /// Opens a route, or changes one.
  ///
  /// [stops] **replaces** the road's stops rather than merging into them: a
  /// route form is a whole description of a road, and a merge would leave a
  /// stop an operator deleted still on the timetable. Passing null leaves
  /// them alone, which is what every caller that predates stops does.
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
  });

  /// Every terminal this operator uses, closed ones included: the console
  /// has to be able to reopen one, and a list that hides them makes that
  /// impossible without a database.
  Future<List<StationSummary>> stations(String operatorId);

  /// Opens a terminal, renames one, or closes one. Null when the city is not
  /// one this market knows.
  Future<StationSummary?> saveStation({
    required String operatorId,
    required String cityCode,
    required String name,
    String? id,
    double? lat,
    double? lng,
    String? boardingNotes,
    bool active = true,
  });

  // ── Timetable ─────────────────────────────────────────────────────────────

  Future<List<PatternSummary>> patterns(String operatorId);

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
  });

  /// Turns a timetable into sellable departures, with their seat rows.
  ///
  /// **This is the method the pilot is blocked on.** Until it runs, departures
  /// exist only because somebody wrote SQL.
  ///
  /// Idempotent over a date range: re-running creates nothing it already
  /// created, because a dispatcher who taps twice must not put two coaches on
  /// one road.
  Future<MaterialisationReport> materialise({
    required String operatorId,
    required String patternId,
    required DateTime from,
    required DateTime to,
  });

  // ── Operations ────────────────────────────────────────────────────────────

  /// Departures on one local calendar day. The dispatcher's screen.
  Future<List<DepartureBoardRow>> board({
    required String operatorId,
    required DateTime localDate,
  });

  Future<Manifest?> manifest({
    required String operatorId,
    required String departureId,
  });

  /// Everything a scanner needs to board this coach with the radio switched
  /// off (ADR-0022): the passengers, their per-ticket rotating secrets, and
  /// the tickets that have been voided since.
  ///
  /// A different read from [manifest] even though both are "who is on this
  /// coach", because the two answer different questions. The dispatcher's
  /// manifest is a document — names, phones, how many boarded — and this one
  /// is a **credential set** the device verifies against for the next eight
  /// hours with nobody watching. It carries secrets the printed list must not,
  /// and it deliberately carries no phone numbers: a conductor's handset is
  /// the most easily lost device in this company.
  Future<BoardingManifestData?> boardingManifest({
    required String operatorId,
    required String departureId,
  });

  // ── Terms ─────────────────────────────────────────────────────────────────

  /// Every version of every refund policy this operator has authored, newest
  /// version of each first, with the current default marked.
  ///
  /// Old versions are listed rather than hidden. A booking sold last March is
  /// judged by the policy as it stood last March (ADR-0015 rule 1), so the
  /// operator answering a question about that booking needs to be able to
  /// read the terms it was actually sold under.
  Future<List<RefundPolicySummary>> refundPolicies(String operatorId);

  /// Stores a policy as a **new version**, never as an edit.
  ///
  /// The same shape as [saveLayout], and the same reason: an UPDATE here
  /// would silently change what somebody who already paid is entitled to.
  /// A name that already exists gets the next version of that policy; a new
  /// name starts at version 1.
  Future<RefundPolicySummary> saveRefundPolicy({
    required String operatorId,
    required String name,
    required RefundPolicy policy,
    required String actorUserId,
    ChangePolicy change,
    MissedPolicy missed,
  });

  /// Points future sales at one version of one policy.
  ///
  /// **Future sales only.** Bookings already made keep the version stamped on
  /// them, which is the whole point of versioning; the console says so before
  /// the operator confirms rather than after (ADR-0015 rule 2).
  ///
  /// Null for [policyId] clears the default, which is how an operator stops
  /// offering self-service refunds entirely.
  Future<RefundPolicySummary?> setDefaultRefundPolicy({
    required String operatorId,
    required String? policyId,
    required int? version,
  });

  /// What cancelling this booking would give back, under the terms it was
  /// sold with.
  ///
  /// A **quote**, not a refund: the vendor reads it to the traveller before
  /// anybody agrees to anything, and the number they read is computed by the
  /// same `quoteRefund` the execution path calls a moment later (ADR-0004).
  /// Null when the reference is not this operator's — which is also what a
  /// reference that does not exist looks like, deliberately.
  Future<RefundOffer?> quoteRefund({
    required String operatorId,
    required String bookingRef,
    required DateTime now,
  });

  /// Cancels the booking and records what is owed.
  ///
  /// Everything in one transaction: the booking state, the seats going back
  /// on sale, the tickets voided, the ledger movement and the claim code. A
  /// refund that released a seat but failed to post the debt would be a seat
  /// sold twice and a traveller owed nothing.
  ///
  /// Returns the issued refund, or null when the booking cannot be refunded —
  /// wrong tenant, wrong state, or a policy that gives nothing back. The
  /// caller re-quotes to find out which.
  Future<IssuedRefund?> refundBooking({
    required String operatorId,
    required String bookingRef,
    required String actorUserId,
    required String reason,
    required DateTime now,
  });

  /// Pays a claim out of a station's drawer and closes it.
  ///
  /// Single-use by construction: the state moves `claim_issued → claimed` in
  /// the same statement that reads it, so two vendors scanning the same code
  /// at two counters cannot both pay it out.
  Future<ClaimedRefund?> claimRefund({
    required String operatorId,
    required String claimCode,
    required String stationId,
    required String actorUserId,
    required DateTime now,
  });

  // ── Getting paid ──────────────────────────────────────────────────────────

  /// Where this operator collects, per rail.
  ///
  /// Includes unverified accounts, unlike the traveller-facing read: an
  /// operator has to be able to see the number they entered and that it is
  /// still waiting to be checked.
  Future<List<PaymentAccountSummary>> paymentAccounts(String operatorId);

  /// Sets the number a rail's payments land in.
  ///
  /// **Saved unverified, always.** A number nobody has proved belongs to this
  /// operator must not receive money, and an operator typing their own number
  /// is not proof — a typo sends every franc to a stranger, permanently and
  /// irreversibly, because mobile money has no chargeback. Verification is a
  /// separate act by somebody who saw the merchant agreement.
  ///
  /// Replacing a number **deactivates** the old one rather than editing it, so
  /// an intent that already paid into it still resolves in a dispute.
  Future<PaymentAccountSummary?> savePaymentAccount({
    required String operatorId,
    required String railId,
    required String msisdn,
    required String displayName,
  });
}

/// A collection account, as the console shows it.
final class PaymentAccountSummary {
  const PaymentAccountSummary({
    required this.id,
    required this.railId,
    required this.msisdn,
    required this.displayName,
    required this.verified,
    required this.active,
  });

  final String id;
  final String railId;
  final String msisdn;
  final String displayName;

  /// Until this is true the rail is not offered to a single traveller. The
  /// console says so plainly rather than showing a number that looks live.
  final bool verified;

  final bool active;
}

/// One line of the dispatcher's day view.
final class DepartureBoardRow {
  const DepartureBoardRow({
    required this.id,
    required this.routeCode,
    required this.departsAt,
    required this.status,
    required this.capacity,
    required this.sold,
    required this.held,
    this.vehicleRegistration,
  });

  final String id;
  final String routeCode;
  final DateTime departsAt;
  final String status;
  final int capacity;
  final int sold;

  /// Shown beside `sold` rather than folded into it. A held seat is not
  /// revenue and a dispatcher deciding whether to add a coach needs to know
  /// which of the two they are looking at.
  final int held;

  final String? vehicleRegistration;

  int get available => capacity - sold - held;
}

/// One stored version of one refund policy, as the console lists it.
final class RefundPolicySummary {
  const RefundPolicySummary({
    required this.id,
    required this.version,
    required this.name,
    required this.policy,
    required this.isDefault,
    required this.effectiveFrom,
    this.change = ChangePolicy.standard,
    this.missed = MissedPolicy.notOffered,
    this.bookingCount = 0,
  });

  final String id;
  final int version;
  final String name;
  final RefundPolicy policy;

  /// What moving to another departure costs under this version. Stored on the
  /// same row and stamped by the same `(id, version)` pair as the refund
  /// terms, so a booking's change terms are the ones it was sold under.
  final ChangePolicy change;

  /// What happens to somebody who was late, under the same version stamp.
  final MissedPolicy missed;

  /// Whether new sales are stamped with this version right now. At most one
  /// version of one policy is true here.
  final bool isDefault;

  final DateTime effectiveFrom;

  /// How many bookings were sold under this exact version. Shown because it
  /// is the honest answer to "can I just change this?" — every one of these
  /// is somebody who is entitled to these terms and not to the new ones.
  final int bookingCount;
}

/// What a booking would get back, and under whose terms.
final class RefundOffer {
  const RefundOffer({
    required this.bookingRef,
    required this.state,
    required this.departsAt,
    required this.fare,
    required this.serviceFee,
    required this.policy,
    required this.policyName,
    this.quote,
    this.failureCode,
  });

  final String bookingRef;
  final String state;
  final DateTime departsAt;
  final Money fare;
  final Money serviceFee;

  /// The version the booking was **sold under**, not the operator's current
  /// default. Null when it was sold before the operator wrote any terms, which
  /// is the honest answer rather than applying today's policy retroactively.
  final RefundPolicy? policy;
  final String? policyName;

  /// Null when the policy refuses — outside the window, a non-refundable
  /// fare, already departed. [failureCode] then says which.
  final RefundQuote? quote;
  final String? failureCode;

  bool get isRefundable => quote != null && quote!.refundable.minor > 0;
}

/// A refund that has been approved and is waiting to be collected.
final class IssuedRefund {
  const IssuedRefund({
    required this.id,
    required this.bookingRef,
    required this.amount,
    required this.destination,
    required this.state,
    this.claimCode,
    this.claimExpiresAt,
  });

  final String id;
  final String bookingRef;
  final Money amount;
  final String destination;
  final String state;

  /// What the traveller shows at the counter. Null for destinations that do
  /// not end at a counter.
  final String? claimCode;
  final DateTime? claimExpiresAt;
}

/// A claim that has just been paid out of a drawer.
final class ClaimedRefund {
  const ClaimedRefund({
    required this.id,
    required this.bookingRef,
    required this.amount,
    required this.stationId,
  });

  final String id;
  final String bookingRef;
  final Money amount;
  final String stationId;
}
