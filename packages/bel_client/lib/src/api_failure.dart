import 'package:bel_contracts/bel_contracts.dart';

/// Why a call did not produce an answer.
///
/// The distinction that matters most on a Congolese network is between
/// **"the server said no"** and **"we never heard back"**. They demand
/// completely different things of the user: one is "choose another seat", the
/// other is "we are still trying". Collapsing them into a single "error" is
/// how an app ends up telling somebody their payment failed when in fact it
/// may well have succeeded.
sealed class ApiFailure implements Exception {
  const ApiFailure();

  /// The catalog key a surface renders. The client never produces prose.
  String get messageKey;

  /// Whether retrying the identical request could plausibly work.
  bool get retryable;

  String? get traceId => null;
}

/// The server answered, and the answer was a refusal.
final class ServerRefused extends ApiFailure {
  const ServerRefused(this.status, this.error);

  final int status;
  final ApiError error;

  @override
  String get messageKey => error.messageKey;

  @override
  bool get retryable => error.retryable;

  @override
  String? get traceId => error.traceId;

  String get code => error.code;
  Map<String, Object?> get params => error.params;

  @override
  String toString() => 'ServerRefused($status, ${error.code})';
}

/// No answer arrived. The request may or may not have been executed.
///
/// This is the honest state and it is deliberately not merged with anything
/// else. On a mutating call the correct response is to retry **with the same
/// idempotency key**, which is exactly why every mutating method takes one.
final class NetworkUnreachable extends ApiFailure {
  const NetworkUnreachable([this.detail]);

  final String? detail;

  @override
  String get messageKey => 'errors.network.unreachable';

  @override
  bool get retryable => true;

  @override
  String toString() => 'NetworkUnreachable($detail)';
}

/// The server took too long. Same ambiguity as [NetworkUnreachable], and the
/// same answer — but worth naming separately because the wording differs: a
/// slow server is not the same story as no signal, and travellers on 2G know
/// the difference better than we do.
final class RequestTimedOut extends ApiFailure {
  const RequestTimedOut(this.after);

  final Duration after;

  @override
  String get messageKey => 'errors.network.timeout';

  @override
  bool get retryable => true;

  @override
  String toString() => 'RequestTimedOut(${after.inSeconds}s)';
}

/// The server answered with something we cannot parse.
///
/// Almost always a version skew: an app three releases old meeting a field it
/// has never seen. Not retryable — the same request produces the same
/// unparseable answer — and the surface says "update the app" rather than
/// "try again", which is the only advice that can actually help.
final class UnreadableResponse extends ApiFailure {
  const UnreadableResponse(this.detail);

  final String detail;

  @override
  String get messageKey => 'errors.client.unreadable';

  @override
  bool get retryable => false;

  @override
  String toString() => 'UnreadableResponse($detail)';
}

/// Firebase refused the exchange or the refresh.
///
/// Its own failure taxonomy, kept separate from [ServerRefused] because the
/// two mean different things: our API refusing is a fact about the booking,
/// and Firebase refusing is a fact about the session. The recovery differs —
/// the second one means sign in again.
final class FirebaseRefused extends ApiFailure {
  const FirebaseRefused(this.status, this.reason);

  final int status;

  /// Firebase's stable machine-readable reason, e.g. `TOKEN_EXPIRED`.
  final String reason;

  @override
  String get messageKey => 'errors.auth.unauthorized';

  /// Never. Every one of these needs the traveller to sign in again, and
  /// "try again" on a dead refresh token is a loop.
  @override
  bool get retryable => false;

  @override
  String toString() => 'FirebaseRefused($status, $reason)';
}
