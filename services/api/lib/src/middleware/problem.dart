import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// Turns a domain failure into an HTTP response.
///
/// One place, so a failure the domain can produce always reaches the client as
/// a named code rather than a generic 500 — which is what makes twelve
/// distinct payment failures possible in the UI.
final class Problem {
  const Problem._();

  static int statusFor(String code) => switch (code) {
    // Malformed, or refused by a rule the client could have checked itself:
    // too many seats, the same seat twice, no seats at all. 400 rather than
    // the 422 default, because these are wrong *requests*, not requests the
    // world happened to refuse. The distinction matters to a client deciding
    // whether a retry could ever help.
    // An address the client could have checked itself, and a code that is
    // wrong in a way retrying will not fix.
    ErrorCode.badRequest ||
    ErrorCode.emailInvalid ||
    ErrorCode.phoneInvalid => 400,
    ErrorCode.unauthorized ||
    ErrorCode.otpIncorrect ||
    ErrorCode.otpExpired ||
    ErrorCode.mfaIncorrect ||
    ErrorCode.mfaExpired => 401,
    ErrorCode.forbidden ||
    ErrorCode.operatorSuspended ||
    ErrorCode.mfaEnrolmentRequired => 403,
    ErrorCode.notFound || ErrorCode.bookingInvalidRef => 404,
    // 413 and 415 rather than a blanket 422: "your logo is too big" and "we do
    // not take GIFs" are different problems with different fixes, and the
    // status is the first thing a developer integrating against this reads.
    ErrorCode.assetTooLarge => 413,
    ErrorCode.assetUnsupportedType => 415,
    ErrorCode.conflict ||
    ErrorCode.seatUnavailable ||
    ErrorCode.holdAlreadyConsumed ||
    ErrorCode.departureSoldOut ||
    ErrorCode.idempotencyKeyReused ||
    ErrorCode.mfaAlreadyEnrolled => 409,
    // 410: the resource genuinely existed and is now gone. A hold that
    // timed out is not a 400 — the client did nothing wrong.
    ErrorCode.holdExpired || ErrorCode.holdExpiredDuringPayment => 410,
    ErrorCode.rateLimited ||
    ErrorCode.otpTooManyAttempts ||
    ErrorCode.otpResendTooSoon ||
    ErrorCode.otpSourceRateLimited ||
    ErrorCode.mfaLocked => 429,
    ErrorCode.unavailable ||
    ErrorCode.paymentPspUnavailable ||
    ErrorCode.storageUnavailable => 503,
    ErrorCode.internal => 500,
    // 422: well-formed, but the rules refuse it. Refund windows, policy
    // limits and payment declines all land here.
    _ => 422,
  };

  /// Domain failures already carry a code and parameters, so this is a rename
  /// rather than a translation.
  static ApiError fromFailure(DomainFailure failure, {String? traceId}) =>
      ApiError(code: failure.code, params: failure.params, traceId: traceId);

  static ApiError unauthorized({String? traceId}) =>
      ApiError(code: ErrorCode.unauthorized, traceId: traceId);

  static ApiError forbidden({String? capability, String? traceId}) => ApiError(
    code: ErrorCode.forbidden,
    params: capability == null ? const {} : {'capability': capability},
    traceId: traceId,
  );

  static ApiError notFound({String? traceId}) =>
      ApiError(code: ErrorCode.notFound, traceId: traceId);

  /// An unexpected exception. The message is never sent to the client — a
  /// stack trace leaks internals, and it would be in the wrong language
  /// anyway. The trace id is what connects the two.
  static ApiError internal({required String traceId}) =>
      ApiError(code: ErrorCode.internal, traceId: traceId);
}
