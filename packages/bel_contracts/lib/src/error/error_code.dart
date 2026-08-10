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

  /// Sold before the operator wrote any terms. Refusing is the honest answer:
  /// applying today's policy to a booking made under none is inventing a
  /// contract after the fact (ADR-0015 rule 1).
  static const refundNoPolicy = 'refund.no_policy';

  /// A reservation nobody paid for is cancelled, not refunded.
  static const refundNotConfirmed = 'refund.not_confirmed';

  static const refundNotPossible = 'refund.not_possible';

  /// One answer for unknown, already collected and expired. A counter that
  /// distinguishes them tells somebody holding a guessed code which guess was
  /// closer.
  static const refundClaimNotOpen = 'refund.claim_not_open';
  static const rescheduleTooCloseToDeparture =
      'reschedule.too_close_to_departure';
  static const rescheduleSameDeparture = 'reschedule.same_departure';

  // ── Identity ───────────────────────────────────────────────────────────
  static const phoneInvalid = 'phone.invalid';
  static const otpIncorrect = 'otp.incorrect';
  static const otpExpired = 'otp.expired';
  static const otpTooManyAttempts = 'otp.too_many_attempts';
  static const emailInvalid = 'email.invalid';

  /// Asked for a new code before the cooldown elapsed. Retryable, but only
  /// after waiting — which is why it carries the wait rather than a bare 429.
  static const otpResendTooSoon = 'otp.resend_too_soon';

  /// One host has asked for too many codes in an hour. Not about the address
  /// — about the caller — and deliberately loose, because carrier-grade NAT
  /// means one address is routinely one building (migration 0016).
  static const otpSourceRateLimited = 'otp.source_rate_limited';

  // ── Second factor (ADR-0013) ───────────────────────────────────────────

  /// The authenticator code did not match. Deliberately distinct from
  /// [otpIncorrect]: the recovery a person needs is different — check the
  /// clock on their phone, not their inbox.
  static const mfaIncorrect = 'mfa.incorrect';

  /// The half-session between "the emailed code was right" and "the
  /// authenticator code was right" has expired. Start again.
  static const mfaExpired = 'mfa.expired';

  /// Too many wrong codes in a row. Carries the wait: a factor locked with no
  /// stated end is a support call.
  static const mfaLocked = 'mfa.locked';

  /// The surface requires a second factor and this account has none enrolled.
  static const mfaEnrolmentRequired = 'mfa.enrolment_required';

  /// Enrolment was asked for on an account that already has a **confirmed**
  /// factor. Replacing one is its own act — silently overwriting it here would
  /// turn a stray click into a lockout of the person whose phone still holds
  /// the old secret.
  static const mfaAlreadyEnrolled = 'mfa.already_enrolled';

  // ── Onboarding (03-operator-lifecycle.md §2.2) ─────────────────────────

  /// This account already has an application in flight. Not a duplicate
  /// request — a second business, which is a conversation rather than a form.
  static const applicationAlreadyExists = 'application.already_exists';

  /// Nothing to save or submit: this account has never started one.
  static const applicationNotFound = 'application.not_found';

  /// Under review, approved or rejected. The wizard reopens when a reviewer
  /// asks for information and not before, because an application being edited
  /// underneath the person reading it is worse than a locked one.
  static const applicationLocked = 'application.locked';

  /// Submitted with gaps. The client already knew — the checklist is domain
  /// code both sides compile — so this is the server declining to take its
  /// word for it.
  static const applicationIncomplete = 'application.incomplete';

  // ── Brand assets (03-operator-lifecycle.md §2.4) ───────────────────────

  /// Not PNG, JPEG or SVG — sniffed from the bytes, never from the header the
  /// caller sent.
  static const assetUnsupportedType = 'asset.unsupported_type';

  /// Over the budget for its kind: 40 KB for a logo, 120 KB for a cover. This
  /// ships to every traveller's phone on a metered bundle (ADR-0009).
  static const assetTooLarge = 'asset.too_large';

  /// Within the byte budget but too many pixels. A 40 KB PNG can be 4000 px
  /// square, and decoding that costs 64 MB of bitmap for a mark rendered at
  /// 32 dp.
  static const assetTooWide = 'asset.too_wide';

  /// Truncated, or otherwise not measurable. A file we cannot measure is a
  /// file we cannot bound.
  static const assetUnreadable = 'asset.unreadable';

  /// This deployment has nowhere to put a file. Distinct from a refusal:
  /// nothing the caller sent was wrong.
  static const storageUnavailable = 'storage.unavailable';

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
