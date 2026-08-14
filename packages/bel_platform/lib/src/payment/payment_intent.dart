import '../money/money.dart';
import '../shared/failure.dart';
import '../shared/result.dart';

/// Where a payment attempt has got to.
///
/// ```
///                     created
///                        │ initiate()
///                        ▼
///    ┌──────────────── pending ────────────────┐
///    │                   │                      │
///    │  callback ───────┤├──────── poll        │
///    │                   ▼                      │
///    │              authorized                  │
///    │                   │ capture              │
///    │                   ▼                      │
///    │               CAPTURED  ──▶ ticket issued here, and ONLY here
///    │
///    ├──▶ FAILED         declined / insufficient / wrong PIN
///    ├──▶ EXPIRED        user never responded in the window
///    ├──▶ CANCELLED      user backed out
///    └──▶ INDETERMINATE  no terminal answer in 15 min → reconciliation queue
/// ```
///
/// [indeterminate] is the state most systems forget, and it is the one that
/// generates angry customers. It is first-class here: it has a queue, a
/// worker, an admin screen and a human behind it.
enum PaymentState {
  created,
  pending,
  authorized,
  captured,
  failed,
  expired,
  cancelled,
  indeterminate;

  /// Money has definitively moved.
  bool get isSettled => this == captured;

  /// No further automatic transition will happen.
  bool get isTerminal =>
      this == captured ||
      this == failed ||
      this == expired ||
      this == cancelled;

  /// Still worth polling the PSP about.
  bool get isInFlight =>
      this == pending || this == authorized || this == indeterminate;

  String get labelKey => 'enum.PaymentState.$name';
}

/// Why an attempt failed. One code, one sentence, one recovery — never
/// "Payment failed. Try again." (`04-payments.md` §5).
enum PaymentFailureCode {
  insufficientFunds(retryable: true, keepsHold: true),
  wrongPin(retryable: true, keepsHold: true),
  userDeclined(retryable: true, keepsHold: true),
  timeoutNoResponse(retryable: true, keepsHold: true),
  wrongOperatorForMsisdn(retryable: true, keepsHold: true),
  subscriberNotFound(retryable: true, keepsHold: true),
  subscriberBarred(retryable: false, keepsHold: true),
  limitExceeded(retryable: true, keepsHold: true),
  pspUnavailable(retryable: true, keepsHold: true),
  networkLost(retryable: true, keepsHold: true),

  /// Rare, ugly, and the one that generates the loudest complaints — so it is
  /// modelled explicitly and tested rather than discovered in production.
  holdExpiredDuringPayment(retryable: false, keepsHold: false);

  const PaymentFailureCode({required this.retryable, required this.keepsHold});

  /// Whether offering "try again" is honest.
  final bool retryable;

  /// Whether the seat stays reserved while the traveller recovers.
  final bool keepsHold;

  /// Wire code, and the stem of the catalog key. The app renders
  /// `errors.payment.<wire>.title` / `.body` / `.action` in the reader's own
  /// language — the server never sends prose.
  String get wire => switch (this) {
    insufficientFunds => 'payment.insufficient_funds',
    wrongPin => 'payment.wrong_pin',
    userDeclined => 'payment.user_declined',
    timeoutNoResponse => 'payment.timeout_no_response',
    wrongOperatorForMsisdn => 'payment.wrong_operator_for_msisdn',
    subscriberNotFound => 'payment.subscriber_not_found',
    subscriberBarred => 'payment.subscriber_barred',
    limitExceeded => 'payment.limit_exceeded',
    pspUnavailable => 'payment.psp_unavailable',
    networkLost => 'payment.network_lost',
    holdExpiredDuringPayment => 'hold.expired_during_payment',
  };

  String get messageKey => 'errors.$wire';
}

sealed class PaymentTransitionFailure extends DomainFailure {
  const PaymentTransitionFailure();
}

final class IllegalPaymentTransition extends PaymentTransitionFailure {
  const IllegalPaymentTransition(this.from, this.to);
  final PaymentState from;
  final PaymentState to;
  @override
  String get code => 'payment.illegal_transition';
  @override
  Map<String, Object?> get params => {'from': from.name, 'to': to.name};
  @override
  String toString() => 'IllegalPaymentTransition(${from.name} -> ${to.name})';
}

/// One attempt to move money for one booking.
///
/// Every transition is guarded here and, on the server, taken under a row
/// lock. Callback and poll race constantly in production; because each
/// transition is idempotent and guarded, whichever wins produces the same
/// outcome (ADR-0005).
final class PaymentIntent {
  const PaymentIntent({
    required this.id,
    required this.bookingId,
    required this.railId,
    required this.amount,
    required this.idempotencyKey,
    required this.createdAt,
    this.state = PaymentState.created,
    this.msisdn,
    this.pspReference,
    this.failureCode,
    this.terminalAt,
    this.pollAttempts = 0,
  });

  final String id;
  final String bookingId;

  /// Which rail, e.g. `cg.airtel_money`. A string, so a new country's rails
  /// need no change here.
  final String railId;

  final Money amount;

  /// Generated by the client, reused across every retry of the same attempt.
  /// A duplicate tap can never create a second charge.
  final String idempotencyKey;

  final DateTime createdAt;
  final PaymentState state;
  final String? msisdn;
  final String? pspReference;
  final PaymentFailureCode? failureCode;
  final DateTime? terminalAt;
  final int pollAttempts;

  /// Legal moves. Anything not listed is rejected, which is what stops a
  /// late callback resurrecting a refunded booking.
  static const _allowed = <PaymentState, Set<PaymentState>>{
    // `failed` is reachable straight from `created` because a rail can refuse
    // the request itself — MTN answers 400 for a subscriber it does not know,
    // Airtel a TF for a barred one — and no prompt ever reaches a handset.
    // Routing that through `pending` first would be a fiction the payment
    // events log would then have to carry forever.
    PaymentState.created: {
      PaymentState.pending,
      PaymentState.failed,
      PaymentState.cancelled,
    },
    PaymentState.pending: {
      PaymentState.authorized,
      PaymentState.captured, // some rails capture without a distinct auth
      PaymentState.failed,
      PaymentState.expired,
      PaymentState.cancelled,
      PaymentState.indeterminate,
    },
    PaymentState.authorized: {
      PaymentState.captured,
      PaymentState.failed,
      PaymentState.indeterminate,
    },
    // An indeterminate intent resolves one way or the other, never anywhere
    // else. This is the reconciliation queue's only exit.
    PaymentState.indeterminate: {PaymentState.captured, PaymentState.failed},
    PaymentState.captured: {},
    PaymentState.failed: {},
    PaymentState.expired: {},
    PaymentState.cancelled: {},
  };

  bool canTransitionTo(PaymentState next) =>
      _allowed[state]?.contains(next) ?? false;

  /// Applies a transition.
  ///
  /// **Idempotent by design**: re-applying the state an intent is already in
  /// returns it unchanged rather than failing, because a duplicate callback is
  /// normal traffic, not an error.
  Result<PaymentIntent, PaymentTransitionFailure> transitionTo(
    PaymentState next, {
    required DateTime now,
    String? pspReference,
    PaymentFailureCode? failureCode,
  }) {
    if (state == next) return Ok(this);

    if (!canTransitionTo(next)) {
      return Err(IllegalPaymentTransition(state, next));
    }

    return Ok(
      _copy(
        state: next,
        pspReference: pspReference ?? this.pspReference,
        failureCode: failureCode ?? this.failureCode,
        terminalAt: next.isTerminal ? now : terminalAt,
      ),
    );
  }

  PaymentIntent recordPoll() => _copy(pollAttempts: pollAttempts + 1);

  /// Poll backoff: 5s, 10s, 20s, 40s, then every 60s.
  Duration get nextPollDelay => switch (pollAttempts) {
    0 => const Duration(seconds: 5),
    1 => const Duration(seconds: 10),
    2 => const Duration(seconds: 20),
    3 => const Duration(seconds: 40),
    _ => const Duration(seconds: 60),
  };

  /// After this, an unresolved intent goes to the reconciliation queue rather
  /// than leaving the traveller staring at a spinner.
  static const indeterminateAfter = Duration(minutes: 15);

  bool shouldGiveUpAt(DateTime now) =>
      state == PaymentState.pending &&
      now.difference(createdAt) >= indeterminateAfter;

  /// The ticket is issued here, and only here. No optimistic issuance, ever.
  bool get issuesTicket => state == PaymentState.captured;

  /// Whether the seat stays reserved while the traveller recovers.
  bool get keepsHold => switch (state) {
    PaymentState.failed => failureCode?.keepsHold ?? true,
    PaymentState.expired || PaymentState.cancelled => false,
    _ => true,
  };

  PaymentIntent _copy({
    PaymentState? state,
    String? pspReference,
    PaymentFailureCode? failureCode,
    DateTime? terminalAt,
    int? pollAttempts,
  }) => PaymentIntent(
    id: id,
    bookingId: bookingId,
    railId: railId,
    amount: amount,
    idempotencyKey: idempotencyKey,
    createdAt: createdAt,
    state: state ?? this.state,
    msisdn: msisdn,
    pspReference: pspReference ?? this.pspReference,
    failureCode: failureCode ?? this.failureCode,
    terminalAt: terminalAt ?? this.terminalAt,
    pollAttempts: pollAttempts ?? this.pollAttempts,
  );

  @override
  String toString() => 'PaymentIntent($id, $railId, ${state.name}, $amount)';
}
