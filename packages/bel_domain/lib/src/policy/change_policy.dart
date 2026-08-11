import '../money/money.dart';
import '../shared/failure.dart';
import '../shared/result.dart';

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
