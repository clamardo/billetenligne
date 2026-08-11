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
    required this.reference,
    required this.description,
    this.payerMsisdn,
    this.collectionMsisdn,
    this.returnUrl,
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
  ///
  /// Null on a **card** rail, which pulls from a card number this system
  /// never sees. Nullable rather than an empty string: a rail that reads it
  /// should fail loudly on the day it is wired to the wrong kind, not send a
  /// prompt to "".
  final String? payerMsisdn;

  /// The operator's merchant number the money lands in. Null on a card rail,
  /// where settlement is to a merchant account the PSP holds rather than to a
  /// wallet we can name.
  final String? collectionMsisdn;

  /// Where the PSP sends the traveller back to when they are done.
  ///
  /// Set on a **hosted-checkout** rail and null on every push rail. Mobile
  /// money answers on the handset; a card is entered on somebody else's page,
  /// and the return is how the app knows to stop waiting and start polling.
  /// It is a hint, never authority: the money is confirmed by re-querying the
  /// PSP, exactly as a callback is (ADR-0005 rule 4).
  final String? returnUrl;

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
    this.checkoutUrl,
    this.raw = const {},
  });

  final PaymentState state;
  final PaymentFailureCode? failureCode;

  /// Where to send the traveller to enter their card.
  ///
  /// Set only by a hosted-checkout rail, and only on the first answer. Stored
  /// on the intent rather than held in memory, because the app that opened it
  /// may be killed while somebody is typing a card number into another
  /// application, and the screen they come back to has to be able to offer
  /// the page again.
  final String? checkoutUrl;

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
/// Airtel, MTN, a card PSP, and a fake that can produce every terminal state
/// plus the four callback pathologies (lost, duplicate, out-of-order,
/// after-timeout). **A rail is not production-ready until it passes that
/// suite** (ADR-0005).
abstract interface class PaymentGateway {
  /// `cg.airtel_money`, `cg.mtn_momo`, `cg.card`. Matches
  /// `payment_intents.rail_id`.
  String get railId;

  /// Whether this rail answers on the payer's own handset.
  ///
  /// True for mobile money, where a prompt goes out and somebody types a PIN
  /// in a menu we do not control. False for a hosted checkout, where the
  /// traveller is sent to the PSP's page and comes back — which changes what
  /// the caller must supply (a wallet number, or a return URL) and what the
  /// screen must draw (a "check your handset" wait, or a browser).
  ///
  /// Asked rather than inferred from the id, so adding an aggregator is a
  /// class rather than a string somebody has to remember to add to a list.
  /// Answered by every adapter rather than defaulted here, because a rail
  /// that silently inherited "yes" would be handed a wallet number it has no
  /// use for and no way to complain about.
  bool get pushesToHandset;

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
