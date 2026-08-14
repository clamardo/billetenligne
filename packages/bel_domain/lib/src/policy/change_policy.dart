import 'package:bel_platform/bel_platform.dart';

/// What an operator charges to move somebody to another departure.
///
/// ADR-0012 D-08 and `01-feature-spec.md` §8.1: **free with enough notice, a
/// fee inside the window, refused too close to departure.** Three numbers,
/// and every one of them is a commercial term rather than a constant — a
/// two-coach family business and a carrier running the RN1 hourly will not
/// pick the same ones.
///
/// It lives beside [RefundPolicy] on the same stored row and travels with the
/// booking by the same `(id, version)` stamp, which is what makes "the terms
/// it was sold under" true for changes as well as for refunds without a
/// second versioning scheme to keep honest.
final class ChangePolicy {
  const ChangePolicy({
    this.freeBefore = const Duration(hours: 24),
    this.feeBps = 1000,
    this.cutoff = const Duration(hours: 2),
  });

  /// At least this much notice and the change costs nothing.
  final Duration freeBefore;

  /// Between [cutoff] and [freeBefore], as a share of the fare already paid.
  /// Basis points, so no float ever touches money.
  final int feeBps;

  /// Closer than this and the answer is no. A manifest handed to a conductor
  /// half an hour before boarding is a manifest somebody is working from.
  final Duration cutoff;

  /// The defaults D-08 states, for an operator who has said nothing.
  static const standard = ChangePolicy();

  /// Whether these numbers can be evaluated at all. Checked before the row is
  /// stored, because the failure is silent: a cutoff longer than the free
  /// window means the fee band never exists and nobody notices until the
  /// month's changes are counted.
  bool get isWellFormed =>
      feeBps >= 0 &&
      feeBps <= 10000 &&
      !cutoff.isNegative &&
      freeBefore >= cutoff;

  /// The terms as sentences, as keys rather than prose — the same convention
  /// [RefundPolicy.describe] uses, so one catalog serves the console, the app
  /// and the email (ADR-0008).
  List<String> describe() => [
    'policy.change.free|${freeBefore.inHours}',
    if (feeBps > 0)
      'policy.change.fee|${cutoff.inHours}|${freeBefore.inHours}|'
          '${feeBps ~/ 100}'
    else
      'policy.change.noFee|${cutoff.inHours}|${freeBefore.inHours}',
    'policy.change.cutoff|${cutoff.inHours}',
    // Said last and never optional, like the refund floor: an operator cannot
    // charge somebody for a change the operator itself caused (ADR-0016).
    'policy.change.involuntaryFree',
  ];
}

sealed class ChangeRefusal extends DomainFailure {
  const ChangeRefusal();
}

/// Closer to departure than the operator allows changes.
final class ChangeTooLate extends ChangeRefusal {
  const ChangeTooLate(this.cutoffHours);
  final int cutoffHours;
  @override
  String get code => 'change.too_late';
  @override
  Map<String, Object?> get params => {'hours': cutoffHours};
}

/// The coach has gone. A different sentence from [ChangeTooLate], and the
/// difference matters: one of them is a rule and the other is the world.
final class ChangeAfterDeparture extends ChangeRefusal {
  const ChangeAfterDeparture();
  @override
  String get code => 'change.already_departed';
}

/// The target leaves before the one they hold, or has already gone.
final class ChangeIntoThePast extends ChangeRefusal {
  const ChangeIntoThePast();
  @override
  String get code => 'change.into_the_past';
}

/// Another company, or another road. Neither is a change; both are a new
/// purchase, and pretending otherwise would move a fare between two
/// operators' books on a traveller's tap.
final class ChangeOffRoute extends ChangeRefusal {
  const ChangeOffRoute();
  @override
  String get code => 'change.off_route';
}

/// The departure they already hold.
final class ChangeToTheSameDeparture extends ChangeRefusal {
  const ChangeToTheSameDeparture();
  @override
  String get code => 'change.same_departure';
}

/// The coach filled, or does not have room for the whole party.
final class ChangeDoesNotFit extends ChangeRefusal {
  const ChangeDoesNotFit(this.needed, this.available);
  final int needed;
  final int available;
  @override
  String get code => 'change.does_not_fit';
  @override
  Map<String, Object?> get params => {'needed': needed, 'available': available};
}

/// The change is allowed and costs money, and the money cannot be collected
/// here yet.
///
/// A difference or a fee has to be settled before somebody boards a coach
/// they have not paid for. Collecting it in the app means a payment intent
/// bound to a change that is held but not applied, which is its own slice of
/// work — so until then the amount is stated to the franc and the traveller
/// settles it at a counter, which is how these agencies already work. Refused
/// rather than quietly applied: a movement that leaves an unpaid difference
/// behind is a passenger with a valid QR and an argument at the door.
final class ChangeMustBePaid extends ChangeRefusal {
  const ChangeMustBePaid(this.owedMinor, this.currencyCode);
  final int owedMinor;
  final String currencyCode;
  @override
  String get code => 'change.must_be_paid';
  @override
  Map<String, Object?> get params => {
    'owedMinor': owedMinor,
    'currency': currencyCode,
  };
}

/// A prompt for the difference is already on somebody's handset.
///
/// Refused rather than replaced. The seats a waiting order holds cannot be
/// let go while money may be about to land on them — a capture arriving after
/// the release would pay for a seat somebody else is sitting in.
final class ChangePaymentInFlight extends ChangeRefusal {
  const ChangePaymentInFlight();
  @override
  String get code => 'change.payment_in_flight';
}

/// What moving to one particular departure costs.
final class ChangeQuote {
  const ChangeQuote({
    required this.fee,
    required this.fareDifference,
    required this.owed,
    required this.involuntary,
  });

  /// The operator's charge for changing. Zero outside the fee band.
  final Money fee;

  /// What the new coach costs above the old one. **Never negative**: a move
  /// to a cheaper departure gives nothing back, and the row says so before
  /// anybody taps. Refunding it would mean a disbursement we cannot make or a
  /// counter claim worth less than the counter time it consumes — and either
  /// one discovered *after* the tap would be worse than the sentence.
  final Money fareDifference;

  /// What has to be settled before the movement happens.
  final Money owed;

  /// True when the operator caused the original disruption. Free, always
  /// (ADR-0016) — and it is why this is a field rather than an inference.
  final bool involuntary;

  bool get isFree => owed.minor == 0;
}

/// What moving costs, decided by the same function the server charges with.
///
/// The Flutter app calls it to render "+1 500 FCFA" on every result row
/// before selection, which is what §8.1 asks for; the API calls it to decide
/// what is owed. They cannot disagree, because they are the same code
/// (ADR-0004).
Result<ChangeQuote, ChangeRefusal> quoteChange({
  required Money paidFare,
  required Money newFare,
  required DateTime departsAt,
  required DateTime targetDepartsAt,
  required DateTime now,
  required ChangePolicy policy,
  bool involuntary = false,
}) {
  if (!departsAt.isAfter(now)) return const Err(ChangeAfterDeparture());
  if (!targetDepartsAt.isAfter(now)) return const Err(ChangeIntoThePast());

  final zero = Money.zero(paidFare.currency);

  // The operator's own failure is free, and it is checked before the window:
  // a passenger whose coach broke down at 03:00 is inside every cutoff there
  // is, and charging them the cutoff would be charging them for a breakdown.
  if (involuntary) {
    return Ok(
      ChangeQuote(
        fee: zero,
        fareDifference: zero,
        owed: zero,
        involuntary: true,
      ),
    );
  }

  final lead = departsAt.difference(now);
  if (lead < policy.cutoff) {
    return Err(ChangeTooLate(policy.cutoff.inHours));
  }

  final fee = lead >= policy.freeBefore
      ? zero
      : paidFare.percentBps(policy.feeBps);

  final raw = newFare - paidFare;
  final difference = raw.minor > 0 ? raw : zero;

  return Ok(
    ChangeQuote(
      fee: fee,
      fareDifference: difference,
      owed: fee + difference,
      involuntary: false,
    ),
  );
}

/// What happens to somebody who was late.
///
/// A separate object from [ChangePolicy] because it answers a different
/// question. A change is a decision taken in advance and priced by notice; a
/// missed departure is a person at a counter with a ticket for a coach that
/// has gone, and the only quantity that matters is how long ago it went.
///
/// **Both numbers default to zero, and zero means "not offered".** There is
/// no ADR default to inherit here: honouring a missed ticket is a commercial
/// promise, and a platform that made it on every operator's behalf would be
/// giving away their seats. An operator opts in by answering the question.
final class MissedPolicy {
  const MissedPolicy({this.window = Duration.zero, this.feeBps = 0});

  /// How long after departure the ticket keeps any value.
  final Duration window;

  /// What the transfer costs, as a share of the fare already paid. On top of
  /// any fare difference, and settled before the passenger moves.
  final int feeBps;

  /// The operator has said nothing, so nothing is offered.
  static const notOffered = MissedPolicy();

  bool get isOffered => window > Duration.zero;

  bool get isWellFormed => feeBps >= 0 && feeBps <= 10000 && !window.isNegative;

  /// The terms as catalog keys, never as prose (ADR-0008).
  List<String> describe() => [
    if (!isOffered)
      'policy.missed.notOffered'
    else if (feeBps > 0)
      'policy.missed.fee|${window.inHours}|${feeBps ~/ 100}'
    else
      'policy.missed.free|${window.inHours}',
  ];
}

/// The operator does not move missed passengers at all.
///
/// Said plainly rather than dressed as "too late": a counter agent who knows
/// their company has never offered this needs a different sentence from one
/// whose passenger arrived a day late.
final class MissedNotOffered extends ChangeRefusal {
  const MissedNotOffered();
  @override
  String get code => 'missed.not_offered';
}

/// The window has closed. The ticket is spent.
final class MissedWindowClosed extends ChangeRefusal {
  const MissedWindowClosed(this.windowHours);
  final int windowHours;
  @override
  String get code => 'missed.window_closed';
  @override
  Map<String, Object?> get params => {'hours': windowHours};
}

/// The coach has not left yet, so this is an ordinary change.
///
/// Refused rather than quietly treated as one: the two are priced by
/// different terms, and a counter that could reach the missed-departure fee
/// before departure would be a counter that could charge it to somebody who
/// is simply changing their mind an hour early.
final class MissedNotYet extends ChangeRefusal {
  const MissedNotYet();
  @override
  String get code => 'missed.not_yet';
}

/// Money is owed and no drawer was named.
///
/// A counter transfer is paid in cash across the counter, and cash has to go
/// into a till somebody counts at the end of a shift. The database refuses it
/// too (`missed_transfers_paid_has_a_till`); this says which field to fix.
final class MissedNeedsATill extends ChangeRefusal {
  const MissedNeedsATill();
  @override
  String get code => 'missed.needs_a_till';
}

/// What it costs to put a missed passenger on a later coach.
///
/// The same [ChangeQuote] a change produces, priced by different rules, so
/// the counter screen and the ledger below it need no second shape.
///
/// [involuntary] is honoured here as it is everywhere: a passenger who missed
/// a connection because the operator's own earlier coach broke down did not
/// miss anything (ADR-0016), and is moved free inside every window there is.
Result<ChangeQuote, ChangeRefusal> quoteMissed({
  required Money paidFare,
  required Money newFare,
  required DateTime departedAt,
  required DateTime targetDepartsAt,
  required DateTime now,
  required MissedPolicy policy,
  bool involuntary = false,
}) {
  if (departedAt.isAfter(now)) return const Err(MissedNotYet());
  if (!targetDepartsAt.isAfter(now)) return const Err(ChangeIntoThePast());

  final zero = Money.zero(paidFare.currency);

  // Checked before the window, like every other involuntary case: an operator
  // cannot put a passenger outside a window the operator's own failure
  // pushed them past.
  if (involuntary) {
    return Ok(
      ChangeQuote(
        fee: zero,
        fareDifference: zero,
        owed: zero,
        involuntary: true,
      ),
    );
  }

  if (!policy.isOffered) return const Err(MissedNotOffered());

  final since = now.difference(departedAt);
  if (since > policy.window) {
    return Err(MissedWindowClosed(policy.window.inHours));
  }

  final fee = paidFare.percentBps(policy.feeBps);
  final raw = newFare - paidFare;

  return Ok(
    ChangeQuote(
      fee: fee,
      // A cheaper coach gives nothing back, for the same reason a change
      // does: refunding downward means a disbursement we cannot make or a
      // counter claim worth less than the counter time it consumes.
      fareDifference: raw.minor > 0 ? raw : zero,
      owed: fee + (raw.minor > 0 ? raw : zero),
      involuntary: false,
    ),
  );
}
