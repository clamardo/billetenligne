import '../money/money.dart';
import '../money/ledger.dart';
import '../shared/failure.dart';
import '../shared/result.dart';

/// A corridor an agreement covers, direction-agnostic: `BZV↔PNR`.
///
/// Unordered on purpose. An operator whose coach fails at Dolisie is not
/// going to check whether the agreement was written Brazzaville-first, and a
/// pair of rows for the two directions is a pair that can disagree. The
/// endpoints are sorted at construction, so `BZV↔PNR` and `PNR↔BZV` are the
/// same value and compare equal.
final class Corridor {
  factory Corridor(String a, String b) {
    final x = a.trim().toUpperCase();
    final y = b.trim().toUpperCase();
    if (x.isEmpty || y.isEmpty) {
      throw ArgumentError('a corridor needs two cities');
    }
    if (x == y) throw ArgumentError.value('$x↔$y', 'corridor', 'same city');
    return x.compareTo(y) <= 0 ? Corridor._(x, y) : Corridor._(y, x);
  }

  const Corridor._(this.first, this.second);

  /// The alphabetically first city code, so the pair has one spelling.
  final String first;
  final String second;

  /// `BZV~PNR`. What goes in a column, and what a unique index is built on.
  String get key => '$first~$second';

  static Corridor parse(String key) {
    final parts = key.split('~');
    if (parts.length != 2) {
      throw ArgumentError.value(key, 'corridor', 'expected CITY~CITY');
    }
    return Corridor(parts[0], parts[1]);
  }

  bool covers(String origin, String destination) =>
      Corridor(origin, destination) == this;

  @override
  bool operator ==(Object other) =>
      other is Corridor && other.first == first && other.second == second;
  @override
  int get hashCode => Object.hash(first, second);
  @override
  String toString() => '$first↔$second';
}

/// Where an agreement is in its life.
///
/// `proposed` matters: one operator writes the terms, the other agrees to
/// them, and until then nothing is protected. An agreement one party could
/// switch on alone would be an invoice one party could write alone.
enum ProtectionAgreementState { proposed, active, suspended, ended }

/// A standing agreement between two operators (`08-disruption.md` §5).
///
/// This is the formalisation of something that already happens at Congolese
/// gares: a dispatcher walks down the forecourt, finds a competitor with room,
/// and puts their passengers on that coach. Today it settles in cash, at the
/// time, with an argument. The agreement is the same handshake written down
/// once instead of renegotiated at 05:00 in the rain.
///
/// **Both parties, never one.** [proposedBy] writes the terms; the other
/// operator accepts them, and only then does [state] become
/// [ProtectionAgreementState.active]. The terms are frozen at that moment for
/// the same reason a declaration is (§2.4): this is what one operator will
/// bill the other under, and a rate that can move afterwards is a rate
/// nobody can rely on.
final class ProtectionAgreement {
  const ProtectionAgreement({
    required this.id,
    required this.operatorA,
    required this.operatorB,
    required this.corridors,
    required this.state,
    required this.proposedBy,
    this.reciprocal = true,
    this.rebillDiscountBps = 0,
    this.monthlyCapSeats,
    this.autoAcceptWhenSpareAbove,
  });

  final String id;

  /// The two parties. Ordered by id at construction by whoever builds this,
  /// so a pair has one spelling — see [partiesOf].
  final String operatorA;
  final String operatorB;

  /// Which roads it covers. Empty means none: an agreement that covered
  /// everything by omission would be one nobody read before signing.
  final List<Corridor> corridors;

  final ProtectionAgreementState state;

  /// Which of the two wrote the terms. The *other* one accepts.
  final String proposedBy;

  /// Whether both may call on the other, or only the proposer's counterparty
  /// carries the obligation. Reciprocal is the norm and the default; a small
  /// operator protected by a large one, one way, is a real arrangement too.
  final bool reciprocal;

  /// `tarif public − 15%` is `1500` here (`08-disruption.md` §5).
  ///
  /// A discount rather than a rate, because that is how the term is said out
  /// loud — and because it makes the direction obvious: the receiving
  /// operator bills *less* than they would sell the seat for, which is the
  /// concession that makes the arrangement worth having.
  final int rebillDiscountBps;

  /// `Plafond 40 places / mois`. Null means no ceiling.
  final int? monthlyCapSeats;

  /// Skip the manual accept when the receiving departure would still have
  /// more than this many seats free afterwards.
  ///
  /// The reading of "ou automatique si places > 10": a request that barely
  /// dents the coach is not a decision anybody wants to be woken for, and a
  /// request that would fill it is. Null keeps every request manual.
  final int? autoAcceptWhenSpareAbove;

  bool get isActive => state == ProtectionAgreementState.active;

  /// The two parties in one spelling, so a pair has a single key.
  static (String, String) partiesOf(String x, String y) =>
      x.compareTo(y) <= 0 ? (x, y) : (y, x);

  bool involves(String operatorId) =>
      operatorId == operatorA || operatorId == operatorB;

  String otherParty(String operatorId) =>
      operatorId == operatorA ? operatorB : operatorA;

  /// Whether [requester] may call on the other party under these terms.
  ///
  /// A one-way agreement protects the party that did *not* propose it: an
  /// operator does not write terms obliging their counterparty to rescue them
  /// and then also reserve the right to be the rescuer.
  bool allowsRequestFrom(String requester) {
    if (!isActive || !involves(requester)) return false;
    return reciprocal || requester == proposedBy;
  }

  bool coversJourney(String origin, String destination) {
    for (final c in corridors) {
      if (c.covers(origin, destination)) return true;
    }
    return false;
  }

  /// What the receiving operator bills for one seat.
  ///
  /// The **public fare of the seat being sold**, less the agreed discount —
  /// not what the stranded passenger originally paid. The receiving operator
  /// is giving up a seat they could have sold; the discount is the concession,
  /// and the sending operator's own pricing is none of their business.
  Money rebillPerSeat(Money publicFare) =>
      publicFare.percentBps(10000 - rebillDiscountBps);
}

/// Why a protection request cannot be made or accepted.
sealed class ProtectionRefusal extends DomainFailure {
  const ProtectionRefusal();
}

/// No standing agreement between these two, or it is not active yet.
final class NoAgreement extends ProtectionRefusal {
  const NoAgreement();
  @override
  String get code => 'protection.no_agreement';
}

/// The agreement exists and does not cover this road.
final class CorridorNotCovered extends ProtectionRefusal {
  const CorridorNotCovered(this.corridor);
  final String corridor;
  @override
  String get code => 'protection.corridor_not_covered';
  @override
  Map<String, Object?> get params => {'corridor': corridor};
}

/// One-way, and this is the wrong way.
final class NotProtectedThisWay extends ProtectionRefusal {
  const NotProtectedThisWay();
  @override
  String get code => 'protection.not_this_way';
}

/// `Plafond 40 places / mois`, reached.
final class MonthlyCapReached extends ProtectionRefusal {
  const MonthlyCapReached({required this.cap, required this.used});
  final int cap;
  final int used;
  @override
  String get code => 'protection.cap_reached';
  @override
  Map<String, Object?> get params => {'cap': cap, 'used': used};
}

/// An operator cannot protect themselves — that is option ②.
final class SameOperator extends ProtectionRefusal {
  const SameOperator();
  @override
  String get code => 'protection.same_operator';
}

/// A proposal cannot be accepted by the party that wrote it. The same
/// two-person rule the payout run runs on, for the same reason.
final class CannotAcceptOwnProposal extends ProtectionRefusal {
  const CannotAcceptOwnProposal();
  @override
  String get code => 'protection.own_proposal';
}

/// Whether [requester] may ask [agreement]'s counterparty for [seats] on this
/// journey, given what has already been used this month.
///
/// One function, called by the console before the dispatcher taps and by the
/// server before anything moves (ADR-0004). A dispatcher seeing "40 / 40 used"
/// on the option tile is the difference between a plan and a surprise.
ProtectionRefusal? refuseProtection({
  required ProtectionAgreement? agreement,
  required String requester,
  required String origin,
  required String destination,
  required int seats,
  required int seatsUsedThisMonth,
}) {
  if (agreement == null || !agreement.isActive) return const NoAgreement();
  if (agreement.operatorA == agreement.operatorB) return const SameOperator();
  if (!agreement.involves(requester)) return const NoAgreement();
  if (!agreement.allowsRequestFrom(requester)) {
    return const NotProtectedThisWay();
  }
  if (!agreement.coversJourney(origin, destination)) {
    return CorridorNotCovered(Corridor(origin, destination).key);
  }

  final cap = agreement.monthlyCapSeats;
  if (cap != null && seatsUsedThisMonth + seats > cap) {
    return MonthlyCapReached(cap: cap, used: seatsUsedThisMonth);
  }

  return null;
}

/// Whether a request should skip the manual accept.
///
/// [spareAfter] is what the receiving departure would still have free once the
/// request is honoured. The threshold is the receiving operator's own term,
/// so this is their rule being applied rather than ours.
bool acceptsAutomatically(ProtectionAgreement agreement, int spareAfter) {
  final threshold = agreement.autoAcceptWhenSpareAbove;
  return threshold != null && spareAfter > threshold;
}

/// The settlement for a protection movement (`08-disruption.md` §5).
///
/// ```
/// DR  payable:operator:<sending>     279 000
///     CR  payable:operator:<receiving>     279 000
/// ```
///
/// **No commission, and no cash.** This is a cost-recovery transfer between
/// two operators, not a sale — taxing it would kill exactly the behaviour the
/// agreement exists to encourage. Nothing leaves our bank either: the two
/// payables move against each other and the difference lands in whichever
/// payout run comes next (`04-payments.md` §6.2), which is what "settlement
/// via BilletEnLigne, mensuel" means in the ledger. Neither operator has to
/// trust the other's arithmetic, and neither has to find cash at the gare.
Result<LedgerTransaction, DomainFailure> protectionSettled({
  required String sendingOperatorId,
  required String receivingOperatorId,
  required Money amount,
  required String reference,
}) {
  if (sendingOperatorId == receivingOperatorId) {
    return const Err(SameOperator());
  }
  if (amount.minor <= 0) return const Err(NothingToSettle());

  return LedgerTransaction.balanced([
    LedgerEntry.debit(
      LedgerAccount.payableOperator(sendingOperatorId),
      amount,
      operatorId: sendingOperatorId,
      memo: 'protection $reference',
    ),
    LedgerEntry.credit(
      LedgerAccount.payableOperator(receivingOperatorId),
      amount,
      operatorId: receivingOperatorId,
      memo: 'protection $reference',
    ),
  ]);
}

/// A settlement of nothing. A movement of zero seats, or a fully discounted
/// rebill, is a record rather than a posting.
final class NothingToSettle extends DomainFailure {
  const NothingToSettle();
  @override
  String get code => 'protection.nothing_to_settle';
}
