import 'package:bel_domain/bel_domain.dart';

/// One departure the traveller could move to, priced (`01-feature-spec.md`
/// §8.1).
///
/// The row carries its own answer. §8.1's mock shows the fare difference and
/// the fee **on every result row before selection**, which is the whole
/// design: somebody scanning a list is comparing prices, and a screen that
/// only prices the row you tapped makes them tap five times to compare.
final class ChangeOption {
  const ChangeOption({
    required this.departureId,
    required this.departsAt,
    required this.arrivesAt,
    required this.fare,
    required this.seatsAvailable,
    this.quote,
    this.refusal,
  });

  final String departureId;
  final DateTime departsAt;

  /// On every row, because the question being asked is when they arrive.
  final DateTime arrivesAt;

  final Money fare;
  final int seatsAvailable;

  /// Null when [refusal] is set.
  final ChangeQuote? quote;

  /// Why this row cannot be taken — it does not fit the party, it leaves too
  /// soon. Shown rather than hidden: a departure missing from a list is a
  /// departure somebody phones to ask about.
  final ChangeRefusal? refusal;
}

/// The whole change screen, in one answer.
final class ChangeOptions {
  const ChangeOptions({
    required this.bookingRef,
    required this.originCity,
    required this.destinationCity,
    required this.seatsNeeded,
    required this.currentDepartureId,
    required this.currentDepartsAt,
    required this.paidFare,
    required this.policy,
    required this.options,
    this.involuntary = false,
    this.refusal,
    this.pending,
  });

  final String bookingRef;
  final String originCity;
  final String destinationCity;

  /// The party. Three people who booked together move together or not at all,
  /// which is the same rule the rebooking wave follows.
  final int seatsNeeded;

  final String currentDepartureId;
  final DateTime currentDepartsAt;

  /// What they paid, per seat. Every difference on the screen is against it.
  final Money paidFare;

  final ChangePolicy policy;
  final List<ChangeOption> options;

  /// True when the operator caused a change to this booking already. Every
  /// row is then free, whatever the window says (ADR-0016).
  final bool involuntary;

  /// Set when no change is possible at all — the coach has left, or it is
  /// inside the cutoff. The screen renders the reason and no rows.
  final ChangeRefusal? refusal;

  /// A change of theirs that is already holding seats and waiting to be paid
  /// for.
  ///
  /// On the screen because it is otherwise **invisible**: somebody who backs
  /// out of a PIN prompt comes back to this list with fifteen minutes of held
  /// seats and nothing anywhere saying so, and the only ways out were to pay
  /// or to wait. It is the same reason a reservation shows its payment code
  /// rather than leaving somebody to remember it.
  final ChangeOrder? pending;
}

/// What happened when they tapped.
final class ChangeApplied {
  const ChangeApplied({
    required this.bookingRef,
    required this.departureId,
    required this.departsAt,
    required this.seatLabels,
  });

  final String bookingRef;
  final String departureId;
  final DateTime departsAt;
  final List<String> seatLabels;
}

/// A change that is waiting to be paid for.
///
/// The seats on the target departure are **already held** by this order — it
/// is a promise with an expiry, not an intention. Applying it belongs to the
/// capture and to nothing else: a change applied on `pending` is the free
/// journey an optimistically issued ticket would be (ADR-0005), one departure
/// further along.
final class ChangeOrder {
  const ChangeOrder({
    required this.id,
    required this.bookingId,
    required this.bookingRef,
    required this.toDepartureId,
    required this.departsAt,
    required this.seatLabels,
    required this.fee,
    required this.fareDifference,
    required this.owed,
    required this.expiresAt,
    required this.state,
    this.applied,
  });

  final String id;
  final String bookingId;
  final String bookingRef;
  final String toDepartureId;
  final DateTime departsAt;
  final List<String> seatLabels;

  /// Quoted, and then stored. Recomputing at capture would let a price move
  /// between the tap and the PIN, which is the one window this whole object
  /// exists to close.
  final Money fee;
  final Money fareDifference;
  final Money owed;

  final DateTime expiresAt;

  /// `awaiting_payment`, `applied`, `expired` or `cancelled`.
  final String state;

  /// Set once the money has landed and the booking has moved.
  final ChangeApplied? applied;

  bool get isAwaitingPayment => state == 'awaiting_payment';
  bool get isApplied => state == 'applied';
}

/// One later coach a missed passenger could be put on, priced.
///
/// The same shape as [ChangeOption] with one addition that is the point of
/// the feature: **which yard it leaves from**. A passenger who missed the
/// 06:00 from Mikalou can be put on the 09:30 from Kinsoundi, and an agent
/// who cannot see that on the row is an agent who sends somebody to the wrong
/// side of the city.
final class MissedOption {
  const MissedOption({
    required this.departureId,
    required this.departsAt,
    required this.arrivesAt,
    required this.fare,
    required this.seatsAvailable,
    this.stationName,
    this.boardingNotes,
    this.sameStation = true,
    this.quote,
    this.refusal,
  });

  final String departureId;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final Money fare;
  final int seatsAvailable;

  final String? stationName;
  final String? boardingNotes;

  /// False when this coach leaves from somewhere other than the yard they
  /// were told to come to. Computed on the server so the agent's screen and
  /// the passenger's ticket cannot disagree about what "the other gare" is.
  final bool sameStation;

  final ChangeQuote? quote;
  final ChangeRefusal? refusal;
}

/// The counter's whole screen for a passenger who was late.
final class MissedOptions {
  const MissedOptions({
    required this.bookingRef,
    required this.originCity,
    required this.destinationCity,
    required this.seatsNeeded,
    required this.departedAt,
    required this.paidFare,
    required this.policy,
    required this.options,
    this.fromStationName,
    this.involuntary = false,
    this.refusal,
  });

  final String bookingRef;
  final String originCity;
  final String destinationCity;
  final int seatsNeeded;

  /// When the coach they hold a ticket for actually left.
  final DateTime departedAt;

  final Money paidFare;
  final MissedPolicy policy;
  final List<MissedOption> options;

  /// The yard they were told to come to, when one was named.
  final String? fromStationName;

  final bool involuntary;

  /// Set when nothing can be done: the operator does not offer this, the
  /// window has closed, or the coach has not left yet.
  final ChangeRefusal? refusal;
}

/// What the counter did.
final class MissedTransfer {
  const MissedTransfer({
    required this.bookingRef,
    required this.departureId,
    required this.departsAt,
    required this.seatLabels,
    required this.paid,
    this.stationName,
    this.boardingNotes,
  });

  final String bookingRef;
  final String departureId;
  final DateTime departsAt;
  final List<String> seatLabels;

  /// What was taken across the counter, so the receipt and the drawer agree.
  final Money paid;

  /// Where the new coach leaves from — the sentence the agent says out loud.
  final String? stationName;
  final String? boardingNotes;
}

/// The traveller moving themselves to another departure (§8.1).
///
/// Distinct from `PassengerChoices`, which is the same movement offered after
/// a breakdown: that one is an entitlement the operator opened, priced at
/// nothing and bounded by a deadline. This one is a purchase decision the
/// traveller makes unprompted, priced by the terms they bought under, and
/// available on any day nothing has gone wrong.
abstract interface class RescheduleDesk {
  /// The screen. Null when the reference is not this traveller's — which is
  /// what a reference that does not exist looks like too.
  Future<ChangeOptions?> options({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });

  /// Moves them. Null when the reference is not theirs, so the two verbs
  /// cannot be told apart by somebody guessing references.
  ///
  /// The seats on the new coach are taken **before** the old ones are
  /// released, and the decision is re-taken under the lock: the row was
  /// priced before it, and the coach can fill in between.
  Future<({ChangeApplied? applied, ChangeRefusal? refusal})?> change({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  });

  /// Takes the seats and quotes the difference, without moving anything.
  ///
  /// The path for a change that owes money: the seats are held for the length
  /// of the payment window, the amount is written down as it was quoted, and
  /// the booking stays exactly where it is until the money lands. A change
  /// that turns out to owe nothing at the lock is **applied here and now** and
  /// returned already applied — refusing it because the price fell between the
  /// list and the tap would be an insult with a 409 attached.
  Future<({ChangeOrder? order, ChangeRefusal? refusal})?> reserveChange({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  });

  /// One order, as its traveller sees it. Null when it is not theirs.
  Future<ChangeOrder?> orderById({
    required String changeId,
    required String userId,
  });

  /// Gives the held seats back before the window runs out.
  ///
  /// Worth building rather than leaving to the sweeper, for the same reason
  /// releasing a hold is: seats freed the moment somebody changes their mind
  /// are seats on sale a quarter of an hour sooner, and on a coach that is
  /// nearly full that quarter of an hour is a real sale.
  ///
  /// Null when the reference is not theirs — which is what a reference that
  /// was never issued looks like too. `released` is false with no refusal
  /// when there was nothing waiting: cancelling twice is cancelling once.
  /// A **payment already in flight refuses**, because releasing those seats a
  /// second before a capture lands strands money nobody can put anywhere.
  Future<({bool released, ChangeRefusal? refusal})?> cancelChange({
    required String bookingRef,
    required String userId,
  });

  /// Applies a paid change. Called by the settlement path and nowhere else.
  ///
  /// [posting] is the ledger movement for the difference, computed above this
  /// line by the same code that settles a booking — the money maths does not
  /// belong in an adapter. Idempotent: an order that is no longer
  /// `awaiting_payment` returns what it already did.
  Future<ChangeApplied?> applyPaidChange({
    required String changeId,
    required String intentId,
    required LedgerTransaction posting,
  });

  // ── The passenger who was late ──────────────────────────────────────────

  /// Later coaches for a booking whose departure has gone.
  ///
  /// Scoped to the operator rather than to a traveller: this is a counter
  /// screen. A passenger who missed a coach is standing in front of somebody,
  /// and the decision to honour their ticket is the company's to take — which
  /// is also why it is not in the app.
  ///
  /// Candidates are every later departure of this operator **between the same
  /// two cities**, not on the same route id. That is what lets the 09:30 from
  /// the other gare be offered: a company's two Brazzaville terminals are two
  /// routes, and a passenger does not care which row of our table their coach
  /// belongs to.
  Future<MissedOptions?> missedOptions({
    required String bookingRef,
    required String operatorId,
    required DateTime now,
  });

  /// Moves them, takes the money, and re-signs the ticket — one transaction.
  ///
  /// [stationId] is the drawer the cash goes into, required when anything is
  /// owed and refused when nothing is: money in a till has to say which till,
  /// and a station on a free transfer is a station nobody counted.
  ///
  /// The quote is re-taken under the lock. The row was priced before it, and
  /// a coach can fill between an agent reading a screen and pressing a
  /// button — which at a counter is a genuine two minutes.
  Future<({MissedTransfer? moved, ChangeRefusal? refusal})?> moveMissed({
    required String bookingRef,
    required String operatorId,
    required String toDepartureId,
    required String actorUserId,
    required DateTime now,
    String? stationId,
  });
}

/// The null object, for a server with no database behind it.
final class NoReschedules implements RescheduleDesk {
  const NoReschedules();

  @override
  Future<ChangeOptions?> options({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => null;

  @override
  Future<({ChangeApplied? applied, ChangeRefusal? refusal})?> change({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  }) async => null;

  @override
  Future<({ChangeOrder? order, ChangeRefusal? refusal})?> reserveChange({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  }) async => null;

  @override
  Future<ChangeOrder?> orderById({
    required String changeId,
    required String userId,
  }) async => null;

  @override
  Future<({bool released, ChangeRefusal? refusal})?> cancelChange({
    required String bookingRef,
    required String userId,
  }) async => null;

  @override
  Future<MissedOptions?> missedOptions({
    required String bookingRef,
    required String operatorId,
    required DateTime now,
  }) async => null;

  @override
  Future<({MissedTransfer? moved, ChangeRefusal? refusal})?> moveMissed({
    required String bookingRef,
    required String operatorId,
    required String toDepartureId,
    required String actorUserId,
    required DateTime now,
    String? stationId,
  }) async => null;

  @override
  Future<ChangeApplied?> applyPaidChange({
    required String changeId,
    required String intentId,
    required LedgerTransaction posting,
  }) async => null;
}
