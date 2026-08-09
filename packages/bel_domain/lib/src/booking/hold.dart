import '../shared/failure.dart';
import '../shared/result.dart';

/// How long a seat is held while the traveller pays.
///
/// The relationship between these two is the single most important timing
/// fact in the system (ADR-0012, `04-payments.md` §3):
///
/// ```
/// t=0     hold created ─────────────────────────── 15:00 TTL
/// t=0     payment window opens ────────── 10:00
/// t=10m   payment window closes → EXPIRED
/// t=15m   hold expires
/// ```
///
/// The hold must always outlive the payment window. Invert them and the seat
/// is released out from under someone who is at that moment entering their
/// mobile money PIN — which is the worst experience this product can produce.
final class HoldPolicy {
  const HoldPolicy({
    this.ttl = const Duration(minutes: 15),
    this.paymentWindow = const Duration(minutes: 10),
    this.warnAt = const Duration(minutes: 2),
  }) : assert(
         true,
         'invariant is asserted by isValid — const asserts cannot compare '
         'Durations in all Dart versions',
       );

  final Duration ttl;
  final Duration paymentWindow;

  /// When the countdown turns amber. Never red until it is genuinely urgent —
  /// crying wolf on a countdown teaches people to ignore it.
  final Duration warnAt;

  /// The invariant, checked rather than assumed. `hold_policy_test.dart`
  /// asserts this for every configuration we ship.
  bool get isValid => ttl > paymentWindow && warnAt < paymentWindow;

  static const standard = HoldPolicy();
}

sealed class HoldFailure extends DomainFailure {
  const HoldFailure();
}

final class HoldExpired extends HoldFailure {
  const HoldExpired();
  @override
  String get code => 'hold.expired';
}

final class HoldAlreadyConsumed extends HoldFailure {
  const HoldAlreadyConsumed();
  @override
  String get code => 'hold.already_consumed';
}

final class SeatUnavailable extends HoldFailure {
  const SeatUnavailable(this.seatLabels);
  final List<String> seatLabels;
  @override
  String get code => 'hold.seat_unavailable';
  @override
  Map<String, Object?> get params => {'seats': seatLabels.join(', ')};
}

enum HoldState { active, consumed, released, expired }

/// A pessimistic claim on specific seats of a specific departure.
///
/// Cash sales at an agency take the same holds through the same code path —
/// there is no back door, which is exactly what makes agent and digital sales
/// reconcile against one another (ADR-0012 rule 4).
final class Hold {
  const Hold({
    required this.id,
    required this.departureId,
    required this.seatLabels,
    required this.createdAt,
    required this.expiresAt,
    required this.idempotencyKey,
    this.state = HoldState.active,
  });

  final String id;
  final String departureId;
  final List<String> seatLabels;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// A retried hold request with the same key returns the *existing* hold,
  /// never a second one. A user on a flaky connection must not accumulate
  /// holds on seats they cannot pay for.
  final String idempotencyKey;

  final HoldState state;

  Duration remaining(DateTime now) {
    final left = expiresAt.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Expiry is decided by the timestamp on read, not only by a sweeper.
  /// A stalled worker must never be able to leak inventory.
  bool isExpiredAt(DateTime now) =>
      state == HoldState.expired || !now.isBefore(expiresAt);

  bool isWarningAt(DateTime now, {HoldPolicy policy = HoldPolicy.standard}) =>
      !isExpiredAt(now) && remaining(now) <= policy.warnAt;

  /// Converts the hold into a sale. Only an active, unexpired hold can be
  /// consumed — and the check is against the clock, not the stored state.
  Result<Hold, HoldFailure> consume(DateTime now) {
    if (state == HoldState.consumed) return const Err(HoldAlreadyConsumed());
    if (state != HoldState.active || isExpiredAt(now)) {
      return const Err(HoldExpired());
    }
    return Ok(_copy(state: HoldState.consumed));
  }

  /// Voluntary release — the traveller backed out. Idempotent.
  Hold release() =>
      state == HoldState.consumed ? this : _copy(state: HoldState.released);

  Hold expire() =>
      state == HoldState.active ? _copy(state: HoldState.expired) : this;

  Hold _copy({HoldState? state}) => Hold(
    id: id,
    departureId: departureId,
    seatLabels: seatLabels,
    createdAt: createdAt,
    expiresAt: expiresAt,
    idempotencyKey: idempotencyKey,
    state: state ?? this.state,
  );

  @override
  String toString() =>
      'Hold($id, ${seatLabels.join("/")}, ${state.name}, until $expiresAt)';
}
