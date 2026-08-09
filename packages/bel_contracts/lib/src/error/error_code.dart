/// Every error code the API can return.
///
/// These strings are the contract. They are stable, they appear in client
/// `switch` statements, and each one has a matching entry in the translation
/// catalog at `errors.<code>` (ADR-0008). **The server never sends prose** —
/// it sends a code and parameters, and each surface renders it in its own
/// reader's language.
///
/// Renaming one of these is a breaking API change.
final class ErrorCode {
  const ErrorCode._();

  // ── Transport / generic ────────────────────────────────────────────────
  static const badRequest = 'request.bad';
  static const unauthorized = 'auth.unauthorized';
  static const forbidden = 'auth.forbidden';
  static const notFound = 'resource.not_found';
  static const conflict = 'resource.conflict';
  static const rateLimited = 'request.rate_limited';
  static const internal = 'server.internal';
  static const unavailable = 'server.unavailable';

  /// The same idempotency key arrived with a different body. Almost always a
  /// client bug, and worth surfacing loudly rather than silently picking one.
  static const idempotencyKeyReused = 'request.idempotency_key_reused';

  // ── Inventory ──────────────────────────────────────────────────────────
  static const seatUnavailable = 'hold.seat_unavailable';
  static const holdExpired = 'hold.expired';
  static const holdAlreadyConsumed = 'hold.already_consumed';
  static const holdExpiredDuringPayment = 'hold.expired_during_payment';
  static const departureSoldOut = 'departure.sold_out';
  static const departureClosed = 'departure.closed';
  static const departureCancelled = 'departure.cancelled';

  // ── Payment (mirrors PaymentFailureCode.wire) ──────────────────────────
  static const paymentInsufficientFunds = 'payment.insufficient_funds';
  static const paymentWrongPin = 'payment.wrong_pin';
  static const paymentUserDeclined = 'payment.user_declined';
  static const paymentTimeoutNoResponse = 'payment.timeout_no_response';
  static const paymentWrongOperatorForMsisdn =
      'payment.wrong_operator_for_msisdn';
  static const paymentSubscriberNotFound = 'payment.subscriber_not_found';
  static const paymentSubscriberBarred = 'payment.subscriber_barred';
  static const paymentLimitExceeded = 'payment.limit_exceeded';
  static const paymentPspUnavailable = 'payment.psp_unavailable';
  static const paymentNetworkLost = 'payment.network_lost';
  static const paymentIndeterminate = 'payment.indeterminate';
  static const paymentIllegalTransition = 'payment.illegal_transition';
  static const paymentRailDisabled = 'payment.rail_disabled';
  static const paymentAmountOutOfRange = 'payment.amount_out_of_range';

  // ── Refund / reschedule ────────────────────────────────────────────────
  static const refundOutsideWindow = 'refund.outside_window';
  static const refundFareNotRefundable = 'refund.fare_not_refundable';
  static const refundAlreadyDeparted = 'refund.already_departed';
  static const rescheduleTooCloseToDeparture =
      'reschedule.too_close_to_departure';
  static const rescheduleSameDeparture = 'reschedule.same_departure';

  // ── Identity ───────────────────────────────────────────────────────────
  static const phoneInvalid = 'phone.invalid';
  static const otpIncorrect = 'otp.incorrect';
  static const otpExpired = 'otp.expired';
  static const otpTooManyAttempts = 'otp.too_many_attempts';

  // ── Tenancy / operator lifecycle ───────────────────────────────────────
  static const operatorSuspended = 'operator.suspended';
  static const operatorNotActive = 'operator.not_active';
  static const bookingInvalidRef = 'booking.invalid_ref';

  /// Codes a client may retry unchanged. Anything absent needs the user to do
  /// something different first, and offering "try again" would be dishonest.
  static const retryable = <String>{
    unavailable,
    rateLimited,
    paymentInsufficientFunds,
    paymentWrongPin,
    paymentUserDeclined,
    paymentTimeoutNoResponse,
    paymentWrongOperatorForMsisdn,
    paymentSubscriberNotFound,
    paymentLimitExceeded,
    paymentPspUnavailable,
    paymentNetworkLost,
  };

  /// Catalog key for a code. The one place this mapping lives.
  static String messageKey(String code) => 'errors.$code';
}
