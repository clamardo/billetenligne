import 'package:bel_domain/bel_domain.dart';

import 'payment_gateway.dart';

/// Money going the other way.
///
/// **A separate port, not a method on [PaymentGateway], and that is the whole
/// design.** On every rail in this market a payout is a different product: a
/// different base path, a different token audience, different credentials, and
/// a balance somebody at the operator has to top up before anything can leave.
/// MTN calls it Disbursements and issues a second API user for it; Airtel
/// keys it on a separate `/disbursements` resource with its own PIN. Folding
/// that into the collection adapter would put two sets of credentials behind
/// one interface and make "can this rail pay out?" un-askable — which matters,
/// because the honest answer for a card and for Orange Money is **no**.
abstract interface class DisbursementGateway {
  /// `cg.mtn_momo`, `cg.airtel_money`. The same id the collection rail uses,
  /// because a refund goes back down the rail the money came up and the join
  /// that finds the right adapter is on that string.
  String get railId;

  /// Sends the money. Returns `pending` in the ordinary case — a transfer is
  /// accepted and settled some seconds or minutes later — and a terminal state
  /// only when the rail refused outright.
  ///
  /// [DisbursementRequest.reference] is the idempotency key on every rail that
  /// takes one, and it is the refund id: asking twice for the same refund must
  /// send money once, and the only thing that can guarantee that is a key the
  /// rail deduplicates on.
  Future<PaymentOutcome> disburse(DisbursementRequest request);

  /// Asks the rail what happened, on the poller's backoff.
  ///
  /// Separate from `PaymentGateway.queryStatus` for the reason above: on MTN
  /// the two live under different base paths and a collection id is simply not
  /// found under the disbursement one — which would read as a failed refund
  /// rather than as a question asked in the wrong place.
  Future<PaymentOutcome> queryDisbursement({
    required String reference,
    String? railTransactionId,
  });
}

/// What we ask a rail to send, and where.
final class DisbursementRequest {
  const DisbursementRequest({
    required this.reference,
    required this.amount,
    required this.payeeMsisdn,
    required this.description,
  });

  /// Ours. The refund id, used as the rail's idempotency key.
  final String reference;

  final Money amount;

  /// The wallet the money lands in — the opposite of `payerMsisdn` on a
  /// collection, and the reason these are two types rather than one with a
  /// comment. Copied onto the refund at approval, so a traveller who changes
  /// handsets on Thursday cannot redirect Tuesday's approved refund.
  final String payeeMsisdn;

  /// What the recipient sees in the SMS their operator sends them.
  final String description;
}
