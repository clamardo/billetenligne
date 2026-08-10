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
  });

  final String id;
  final String code;
  final String originCity;
  final String destinationCity;
  final int durationMinutes;
  final bool active;
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
  });

  final String seatLabel;
  final String passengerName;
  final String bookingRef;
  final bool boarded;
  final String? passengerPhone;
  final DateTime? boardedAt;
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

  Future<RouteSummary?> saveRoute({
    required String operatorId,
    required String code,
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
    String? id,
    int? distanceKm,
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
    this.bookingCount = 0,
  });

  final String id;
  final int version;
  final String name;
  final RefundPolicy policy;

  /// Whether new sales are stamped with this version right now. At most one
  /// version of one policy is true here.
  final bool isDefault;

  final DateTime effectiveFrom;

  /// How many bookings were sold under this exact version. Shown because it
  /// is the honest answer to "can I just change this?" — every one of these
  /// is somebody who is entitled to these terms and not to the new ones.
  final int bookingCount;
}
