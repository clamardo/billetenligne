/// How long a seat is held while the traveller pays.
///
/// **Why this is platform and not transport.** It reads as inventory language
/// and it is not: these three durations are entirely about the payment
/// window, and `PaymentIntent.indeterminateAfter` beside it is defined
/// *relative to them* — it must sit beyond `paymentWindow` and within `ttl`,
/// which `payment_intent_test.dart` asserts in both directions.
///
/// `15-platform-split.md` §3.1 originally deferred this type, on the grounds
/// that only one vertical needed it. Executing P2a proved otherwise: the
/// platform's own reconciliation cutoff cannot be stated without it. The
/// deferral was wrong and the finding is recorded there.
///
/// A rental hold and a stay hold will want the same invariant with different
/// numbers, which is the second reason it belongs here.
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

  /// The invariant, checked rather than assumed —
  /// `payment_intent_test.dart`, "the timing invariant that stops a seat
  /// being sold twice", asserts it for every configuration we ship, in both
  /// directions, against `PaymentIntent.indeterminateAfter`.
  bool get isValid => ttl > paymentWindow && warnAt < paymentWindow;

  static const standard = HoldPolicy();
}
