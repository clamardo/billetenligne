import 'package:bel_platform/bel_platform.dart';

/// The six things a dispatcher declares (`08-disruption.md` §1).
///
/// Everything downstream is derived from this one choice: the departure's new
/// status, whether the affected bookings become involuntary, which sentence
/// the passenger receives. That is deliberate — the declaration is made on a
/// phone, at the roadside, possibly in the rain, and every extra question
/// asked there is a question answered wrongly.
enum DisruptionKind {
  /// Will leave or arrive late, and is still going to run.
  delay,

  /// Will not operate at all.
  cancellation,

  /// Failed mid-route with passengers on board. The most common one here, and
  /// the only one where the people affected are already somewhere else.
  breakdownEnRoute,

  /// A different coach. May be smaller than the one sold, which is what makes
  /// it a disruption rather than a note.
  equipmentSwap,

  /// Route changed mid-trip — a washed-out section, a closed bridge.
  diversion,

  /// A whole route unserviceable for a period. Declared against one departure
  /// like the others; what makes it different is that the dispatcher will
  /// declare it against several in a row.
  routeSuspension,
}

/// Why. Kept short and closed, because a free-text cause is a field nobody can
/// ever count.
///
/// This is the input to the route-risk and coach-reliability figures in
/// `08-disruption.md` §6 — which is the whole reason it is an enum and not the
/// note.
enum DisruptionCause {
  mechanical,
  roadClosed,
  weather,
  security,
  noDriver,
  noVehicle,
  checkpoint,
  lateInbound,
  other,
}

sealed class DisruptionRefusal extends DomainFailure {
  const DisruptionRefusal();
}

/// A delay with no new time is not a declaration, it is an apology.
final class DelayNeedsARevisedTime extends DisruptionRefusal {
  const DelayNeedsARevisedTime();
  @override
  String get code => 'disruption.delay_needs_revised_time';
}

final class RevisedTimeIsNotLater extends DisruptionRefusal {
  const RevisedTimeIsNotLater();
  @override
  String get code => 'disruption.revised_time_not_later';
}

/// An estimate in the past is worse than no estimate: it is a promise already
/// broken at the moment it is made.
final class ResolutionIsInThePast extends DisruptionRefusal {
  const ResolutionIsInThePast();
  @override
  String get code => 'disruption.resolution_in_the_past';
}

/// One declared disruption, validated.
///
/// Constructed through [declare], which is the only way to get one — so a
/// disruption that reached the database has already been past every rule
/// below, in the app and on the server, from the same code (ADR-0004).
final class Disruption {
  const Disruption._({
    required this.kind,
    required this.cause,
    required this.departsAt,
    required this.declaredAt,
    this.note,
    this.location,
    this.revisedDepartsAt,
    this.estimatedResolution,
  });

  /// A row read back from storage.
  ///
  /// Deliberately not re-validated. It passed [declareDisruption] on the way
  /// in, and a rule tightened next month must not make last month's
  /// disruption unreadable — a passenger looking at their ticket during a
  /// breakdown is the worst possible moment to discover that.
  const Disruption.stored({
    required this.kind,
    required this.cause,
    required this.departsAt,
    required this.declaredAt,
    this.note,
    this.location,
    this.revisedDepartsAt,
    this.estimatedResolution,
  });

  final DisruptionKind kind;
  final DisruptionCause cause;

  /// When the departure was sold to leave. Carried so the delay is a fact
  /// this object can state rather than one every caller recomputes.
  final DateTime departsAt;

  /// The dispatcher's own words, passed through to the passenger. Optional:
  /// the templated sentence already says what happened, and a field somebody
  /// must fill in at the roadside is a field that delays the message.
  final String? note;

  /// Free text, pre-filled from the last known position (ADR-0014) and
  /// editable — "km 180, RN1, près de Dolisie" is more useful to a passenger
  /// than a pair of coordinates.
  final String? location;

  /// When it will now leave. Required for a [DisruptionKind.delay] and
  /// meaningless for a cancellation.
  final DateTime? revisedDepartsAt;

  /// When the operator expects to have resolved it. This is the number that
  /// buys patience, and §3.3 is explicit that a kept promise about the *next
  /// update* is worth more than an accurate ETA.
  final DateTime? estimatedResolution;

  final DateTime declaredAt;

  /// The departure status this implies, or null when the declaration does not
  /// change it.
  ///
  /// A breakdown en route and a diversion both leave the status alone on
  /// purpose: the coach has already departed, and rewriting it to `delayed`
  /// would put a departure that is physically on the road back into a state
  /// the board reads as "has not left yet".
  String? get departureStatus => switch (kind) {
    DisruptionKind.delay => 'delayed',
    DisruptionKind.cancellation => 'cancelled',
    DisruptionKind.routeSuspension => 'cancelled',
    DisruptionKind.breakdownEnRoute => null,
    DisruptionKind.equipmentSwap => null,
    DisruptionKind.diversion => null,
  };

  /// Whether this permanently exempts the affected bookings from fees and
  /// fare differences (ADR-0016), and entitles a full refund at the platform
  /// floor whatever the operator's own policy says (ADR-0015 rule 4).
  ///
  /// Everything except a short delay. A coach fifteen minutes late is not a
  /// free cancellation for everybody who booked it — treating it as one would
  /// mean an operator who *tells the truth about being late* pays for it,
  /// which is precisely the behaviour this system needs to encourage. Past
  /// [delayThatEntitles] the journey somebody bought is no longer the journey
  /// they are being offered, and it is theirs to walk away from.
  bool get marksInvoluntary => switch (kind) {
    DisruptionKind.delay => delayAtLeast(delayThatEntitles),
    _ => true,
  };

  /// An hour. Stated once, here, rather than in a handler — the app shows the
  /// dispatcher what their declaration will entitle passengers to *before*
  /// they confirm it, and it can only do that by asking the same object.
  static const delayThatEntitles = Duration(hours: 1);

  /// True when the revised time is at least [amount] later than the original.
  /// Null revised time means no declared delay, which is not a long one.
  bool delayAtLeast(Duration amount) {
    final measured = delay;
    return measured != null && measured >= amount;
  }

  /// How much later, or null when nothing said.
  Duration? get delay => revisedDepartsAt?.difference(departsAt);

  /// The catalog key of the sentence the passenger reads (ADR-0008): the
  /// server emits the key and the arguments, and the prose comes from the one
  /// reviewed catalog in the recipient's own language.
  String get summaryKey => 'disruption.summary.${kind.name}';

  /// Which template carries it. Two, because "aucun frais" is only true when
  /// the declaration entitles somebody to something — promising it after a
  /// fifteen-minute delay is a promise a counter agent has to refuse in
  /// person.
  String get messageKey => marksInvoluntary
      ? 'sms.disruptionDeclared.involuntary'
      : 'sms.disruptionDeclared.body';

  /// Whether passengers must be told at all. Always — including at 03:00.
  /// Quiet hours never apply to disruption (`08-disruption.md` §4), because a
  /// 03:00 SMS about a cancelled 05:00 departure is exactly what the
  /// passenger wants.
  bool get notifiesPassengers => true;
}

/// The validated constructor.
///
/// Takes the departure's own time so the delay can be computed here rather
/// than by whoever happens to be calling — a rule that lives in two places is
/// a rule that will disagree with itself.
Result<Disruption, DisruptionRefusal> declareDisruption({
  required DisruptionKind kind,
  required DisruptionCause cause,
  required DateTime departsAt,
  required DateTime now,
  String? note,
  String? location,
  DateTime? revisedDepartsAt,
  DateTime? estimatedResolution,
}) {
  final early = refuseWithoutTheDeparture(
    kind: kind,
    now: now,
    revisedDepartsAt: revisedDepartsAt,
    estimatedResolution: estimatedResolution,
  );
  if (early != null) return Err(early);

  if (revisedDepartsAt != null && !revisedDepartsAt.isAfter(departsAt)) {
    return const Err(RevisedTimeIsNotLater());
  }

  return Ok(
    Disruption._(
      kind: kind,
      cause: cause,
      departsAt: departsAt,
      declaredAt: now,
      note: note?.trim().isEmpty ?? true ? null : note!.trim(),
      location: location?.trim().isEmpty ?? true ? null : location!.trim(),
      revisedDepartsAt: revisedDepartsAt,
      estimatedResolution: estimatedResolution,
    ),
  );
}

/// The rules that can be judged **without** knowing when the coach was due.
///
/// Two callers, one implementation. The console greys out its own confirm
/// button with this; the API route refuses with it before it opens a
/// transaction — which matters because the alternative is a roadside request
/// that travels, locks a departure row and comes back with a 400. The rest of
/// the rules need the scheduled time and are checked in [declareDisruption],
/// where it has been read.
DisruptionRefusal? refuseWithoutTheDeparture({
  required DisruptionKind kind,
  required DateTime now,
  DateTime? revisedDepartsAt,
  DateTime? estimatedResolution,
}) {
  if (kind == DisruptionKind.delay && revisedDepartsAt == null) {
    return const DelayNeedsARevisedTime();
  }
  if (estimatedResolution != null && estimatedResolution.isBefore(now)) {
    return const ResolutionIsInThePast();
  }
  return null;
}
