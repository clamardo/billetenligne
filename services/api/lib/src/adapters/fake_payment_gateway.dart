import 'package:bel_domain/bel_domain.dart';

import '../application/ports/payment_gateway.dart';

/// A rail that can be made to do anything a real one does.
///
/// **This is not a convenience.** ADR-0005 makes it a release gate: a rail is
/// not production-ready until it passes a suite that reproduces every terminal
/// state plus lost, duplicate, out-of-order and after-timeout callbacks. None
/// of those can be provoked on demand against Airtel or MTN, so they are
/// provoked here and the state machine that survives them is the same one both
/// adapters feed.
///
/// It is also what the fakes composition runs on, so a fresh clone can walk
/// the whole payment funnel with no credentials and no network.
final class FakePaymentGateway implements PaymentGateway {
  FakePaymentGateway({
    this.railId = 'cg.fake_money',
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  @override
  final String railId;

  /// A prompt on the payer's own handset, answered with a PIN in a menu we do
  /// not control — which is the asynchrony ADR-0005 exists to contain.
  @override
  bool get pushesToHandset => true;

  final Clock _clock;

  /// How the next request behaves. Set per test; the default is the one that
  /// matters most — a prompt goes out and nothing has happened yet.
  PaymentOutcome onRequest = PaymentOutcome.unknown;

  /// What the rail says when asked. A queue, so a test can script
  /// "pending, pending, captured" and watch the poller converge.
  final List<PaymentOutcome> statusScript = [];

  final List<PaymentRequest> requests = [];
  final List<String> queried = [];

  /// A number that always declines, whatever else is scripted.
  ///
  /// Exists so the traveller app's demo mode has a way to reach the failure
  /// screens without a test harness — the states people never see in
  /// development are the ones that ship broken.
  static const decliningMsisdn = '242060000000';

  /// A number that always settles, one poll later.
  ///
  /// The counterpart [decliningMsisdn] was missing, and the asymmetry showed:
  /// a running dev stack could reach every failure screen and never the paid
  /// one, because `statusScript` is set per test and a server has no test to
  /// set it. So the local demo could open an intent and then watch it sit at
  /// `pending` until it expired.
  ///
  /// Settles on the *query* rather than on the request, because that is the
  /// shape of the real thing: the prompt goes out, the handset answers a
  /// menu we do not control, and the poller finds out afterwards. A rail that
  /// captured synchronously would skip the only interesting state.
  static const capturingMsisdn = '242060000001';

  /// Intents opened from [capturingMsisdn], remembered because `queryStatus`
  /// is told an intent id and never a payer.
  final Set<String> _capturing = {};

  @override
  Future<PaymentOutcome> requestPayment(PaymentRequest request) async {
    requests.add(request);

    if (request.payerMsisdn == capturingMsisdn)
      _capturing.add(request.intentId);

    if (request.payerMsisdn == decliningMsisdn) {
      return const PaymentOutcome(
        state: PaymentState.failed,
        failureCode: PaymentFailureCode.insufficientFunds,
        raw: {'fake': 'declining msisdn'},
      );
    }

    return PaymentOutcome(
      state: onRequest.state,
      failureCode: onRequest.failureCode,
      railTransactionId: 'fake-${request.intentId}',
      raw: {
        'fake': 'requestPayment',
        'at': _clock.now().toIso8601String(),
        ...onRequest.raw,
      },
    );
  }

  @override
  Future<PaymentOutcome> queryStatus({
    required String intentId,
    String? railTransactionId,
  }) async {
    queried.add(intentId);

    // The script drains; the last entry repeats. A poller that runs one more
    // time than the test expected must not fall off the end of a list — that
    // is a test failure about the fake rather than about the code.
    if (statusScript.isEmpty) {
      // An explicit script always wins, so every existing test is unaffected;
      // this only answers where the alternative was `unknown` forever.
      if (_capturing.contains(intentId)) {
        return const PaymentOutcome(
          state: PaymentState.captured,
          raw: {'fake': 'captured (capturingMsisdn)'},
        );
      }
      return PaymentOutcome.unknown;
    }
    if (statusScript.length == 1) return statusScript.first;
    return statusScript.removeAt(0);
  }

  /// Scripts a rail that answers `pending` [times] times and then settles.
  void settlesAfter(int times) {
    statusScript
      ..clear()
      ..addAll([
        for (var i = 0; i < times; i++) PaymentOutcome.unknown,
        const PaymentOutcome(
          state: PaymentState.captured,
          raw: {'fake': 'captured'},
        ),
      ]);
  }

  void declinesWith(PaymentFailureCode code) {
    statusScript
      ..clear()
      ..add(
        PaymentOutcome(
          state: PaymentState.failed,
          failureCode: code,
          raw: {'fake': 'declined', 'code': code.name},
        ),
      );
  }

  /// A rail that never answers.
  ///
  /// The case that produces `indeterminate`, which is the state most systems
  /// forget and the one that generates angry customers.
  void neverAnswers() {
    statusScript
      ..clear()
      ..add(PaymentOutcome.unknown);
  }
}
