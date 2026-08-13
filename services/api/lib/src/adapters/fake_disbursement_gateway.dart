import 'package:bel_domain/bel_domain.dart';

import '../application/ports/disbursement_gateway.dart';
import '../application/ports/payment_gateway.dart';

/// A payout rail that moves no money.
///
/// The default when no telco credentials are configured, which is every local
/// machine and every test run. It exists for the same reason
/// `FakePaymentGateway` does: **the interesting cases are the failures**, and
/// a refund that fails on a barred wallet is not something anybody can produce
/// on demand against a sandbox.
///
/// Deliberately **not** instant. A real disbursement is accepted and settles
/// afterwards, and a fake that answered `captured` on the first call would let
/// a whole class of bug — a ledger posted at request time rather than at
/// settlement — pass every test in this repository.
final class FakeDisbursementGateway implements DisbursementGateway {
  FakeDisbursementGateway({
    this.railId = 'cg.fake',
    this.settleAfter = 1,
    Map<String, PaymentOutcome> scripted = const {},
  }) : _scripted = {...scripted};

  @override
  final String railId;

  /// How many status queries a transfer stays pending for before it settles.
  /// One by default: enough to prove nothing posts at request time, short
  /// enough that a test does not have to loop.
  final int settleAfter;

  final Map<String, PaymentOutcome> _scripted;
  final Map<String, int> _asked = {};

  /// Makes the next transfer for [reference] end this way.
  ///
  /// The whole point of the fake: `insufficientFunds` on a payout means *our*
  /// float is empty, which is an operations failure rather than a traveller's,
  /// and the two must not produce the same sentence.
  void script(String reference, PaymentOutcome outcome) =>
      _scripted[reference] = outcome;

  /// Every reference this gateway was asked to send, in order. A test asserting
  /// "asked once" needs this; a test asserting "asked twice" is asserting a bug.
  final List<String> sent = [];

  @override
  Future<PaymentOutcome> disburse(DisbursementRequest request) async {
    sent.add(request.reference);

    final scripted = _scripted[request.reference];
    // A scripted *refusal* is refused outright, exactly as a rail refuses
    // before anything is queued. A scripted success still has to settle.
    if (scripted != null && scripted.state == PaymentState.failed) {
      return scripted;
    }

    return PaymentOutcome(
      state: PaymentState.pending,
      railTransactionId: 'fake-${request.reference}',
      raw: {'reference': request.reference, 'amount': request.amount.minor},
    );
  }

  @override
  Future<PaymentOutcome> queryDisbursement({
    required String reference,
    String? railTransactionId,
  }) async {
    final asked = (_asked[reference] ?? 0) + 1;
    _asked[reference] = asked;

    final scripted = _scripted[reference];
    if (scripted != null && asked > settleAfter) return scripted;
    if (asked > settleAfter) {
      return PaymentOutcome(
        state: PaymentState.captured,
        railTransactionId: railTransactionId,
        raw: {'reference': reference, 'status': 'SUCCESSFUL'},
      );
    }

    return PaymentOutcome(
      state: PaymentState.pending,
      railTransactionId: railTransactionId,
      raw: {'reference': reference, 'status': 'PENDING'},
    );
  }
}
