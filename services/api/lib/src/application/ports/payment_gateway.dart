import 'package:bel_domain/bel_domain.dart';

/// What we ask a rail to do.
///
/// Deliberately not "charge this card". Mobile money is a *request* to a
/// handset that a human then answers with a PIN, and modelling it as anything
/// synchronous is how the asynchrony leaks into every screen and every table
/// (ADR-0005).
final class PaymentRequest {
  const PaymentRequest({
    required this.intentId,
    required this.amount,
    required this.payerMsisdn,
    required this.collectionMsisdn,
    required this.reference,
    required this.description,
  });

  /// Ours, and the idempotency key on every rail that accepts one. MTN keys
  /// its whole transaction on it (`X-Reference-Id`); Airtel echoes it back as
  /// our reference beside an id of its own.
  final String intentId;

  final Money amount;

  /// The wallet the money is pulled FROM, which is **not necessarily the
  /// signed-in traveller's number**. Somebody whose own wallet is empty pays
  /// from a relative's, standing next to them and reading out the PIN prompt.
  /// Requiring these to match is the obvious validation to write and it breaks
  /// the most common way a ticket gets paid for in this market.
  final String payerMsisdn;

  /// The operator's merchant number the money lands in.
  final String collectionMsisdn;

  /// What the traveller sees in the USSD prompt on their handset. Short: the
  /// prompt is a couple of lines on a feature phone.
  final String reference;
  final String description;
}

/// What a rail said, normalised.
///
/// Every adapter maps its own vocabulary onto this, so nothing above the
/// adapter ever switches on a telco's string. The mapping is the interesting
/// part of each adapter and it is where the failure taxonomy is decided.
final class PaymentOutcome {
  const PaymentOutcome({
    required this.state,
    this.failureCode,
    this.railTransactionId,
    this.raw = const {},
  });

  final PaymentState state;
  final PaymentFailureCode? failureCode;

  /// What the rail calls this transaction. Kept because a re-query has to use
  /// whichever identifier that rail actually keys on, and the two rails
  /// disagree about which one that is.
  final String? railTransactionId;

  /// Exactly as received. Written to `payment_events` and never normalised
  /// away — when a dispute arrives six weeks later this is the only thing
  /// that settles it.
  final Map<String, Object?> raw;

  /// **The state a rail is not allowed to leave us in silently.**
  ///
  /// A network error mid-request means the push may or may not have reached
  /// the handset, and the money may or may not have moved. Reporting that as
  /// `failed` is a lie that costs a customer their seat and us their trust;
  /// reporting it as `pending` is the truth, and the poller resolves it.
  static const unknown = PaymentOutcome(state: PaymentState.pending);
}

/// One rail.
///
/// Airtel, MTN, and a fake that can produce every terminal state plus the
/// four callback pathologies (lost, duplicate, out-of-order, after-timeout).
/// **A rail is not production-ready until it passes that suite** (ADR-0005).
abstract interface class PaymentGateway {
  /// `cg.airtel_money`, `cg.mtn_momo`. Matches `payment_intents.rail_id`.
  String get railId;

  /// Pushes the prompt to the payer's handset.
  ///
  /// Returns `pending` in the ordinary case — the traveller has not typed
  /// their PIN yet — and only ever returns a terminal state when the rail
  /// refused outright.
  Future<PaymentOutcome> requestPayment(PaymentRequest request);

  /// Asks the rail what happened. Called by the poller on a backoff, and
  /// **again after every callback**: a callback is untrusted input, so we
  /// verify it and then re-query for authoritative status rather than
  /// mutating state from its body (ADR-0005 rule 4).
  Future<PaymentOutcome> queryStatus({
    required String intentId,
    String? railTransactionId,
  });
}
