import 'package:bel_domain/bel_domain.dart';

/// Where an operator collects, for one rail.
final class CollectionAccount {
  const CollectionAccount({
    required this.railId,
    required this.msisdn,
    required this.displayName,
    required this.verified,
  });

  final String railId;
  final String msisdn;

  /// Shown to the traveller beside the number before they press pay. Paying a
  /// number you do not recognise is the moment people abandon, and the
  /// operator's name next to it is what stops that.
  final String displayName;

  /// A number nobody has proved belongs to the operator must not receive
  /// money — so an unverified account is never offered.
  final bool verified;
}

/// A payment attempt, as the application layer knows it.
final class PaymentIntentRecord {
  const PaymentIntentRecord({
    required this.id,
    required this.bookingId,
    required this.operatorId,
    required this.railId,
    required this.amount,
    required this.state,
    required this.payerMsisdn,
    required this.collectionMsisdn,
    required this.createdAt,
    this.expiresAt,
    this.failureCode,
    this.railTransactionId,
  });

  final String id;
  final String bookingId;
  final String operatorId;
  final String railId;
  final Money amount;
  final PaymentState state;
  final String payerMsisdn;
  final String collectionMsisdn;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final PaymentFailureCode? failureCode;
  final String? railTransactionId;
}

abstract interface class PaymentStore {
  /// The rails an operator can actually be paid on.
  ///
  /// Only live, verified accounts. An operator with no verified account has
  /// no mobile money rails, and the app says so rather than offering a button
  /// that fails.
  Future<List<CollectionAccount>> collectionAccounts(String operatorId);

  /// Opens an intent against a booking that is waiting to be paid.
  ///
  /// Returns null when the booking is not the caller's, is not
  /// `pending_payment`, or the operator has no verified account on that rail.
  /// One answer for all three: none of them is actionable by the client
  /// beyond "choose again".
  Future<PaymentIntentRecord?> open({
    required String bookingId,
    required String userId,
    required String railId,
    required String payerMsisdn,
    required bool payerIsAccountHolder,
    required String idempotencyKey,
    required Duration window,
  });

  /// The traveller's own view of an attempt.
  Future<PaymentIntentRecord?> byId({
    required String intentId,
    required String userId,
  });

  /// Records what a rail said, and moves the intent if the transition is
  /// legal.
  ///
  /// **Every callback and every poll response is written**, whether or not it
  /// changed anything — `payment_events` is append-only and is the only thing
  /// that settles a dispute six weeks later.
  ///
  /// Returns the intent as it now stands. A refused transition is not an
  /// error: an out-of-order callback arriving after a capture is a normal
  /// event on these rails, and the right response is to keep the capture.
  Future<PaymentIntentRecord?> recordOutcome({
    required String intentId,
    required PaymentState state,
    required String source,
    required Map<String, Object?> raw,
    PaymentFailureCode? failureCode,
    String? railTransactionId,
  });

  /// Intents still worth asking about, oldest poll first.
  Future<List<PaymentIntentRecord>> inFlight({int limit = 100});

  /// Marks an intent as having been polled, whatever the answer.
  Future<void> markPolled(String intentId);
}
