import 'package:bel_api/src/application/pay_for_booking.dart';
import 'package:bel_api/src/application/ports/payment_store.dart';
import 'package:bel_domain/bel_domain.dart';

import 'sweepers.dart';

/// Asks the rails what happened to payments nobody has heard back about.
///
/// **This is not an optimisation, unlike the other passes.** Callbacks get
/// lost — that is a fact about these networks, not a hypothetical — and a
/// traveller whose money left their wallet while our row still says `pending`
/// has paid for a seat they cannot board. Every other pass in this service is
/// tidy-up; this one is the second half of a guarantee.
///
/// Two behaviours carry it:
///
///   * **Backoff, not a fixed interval.** 5 s, 10 s, 20 s, 40 s, then every
///     60 s — the schedule the domain already owns (`nextPollDelay`). A
///     hundred handsets paying at 06:00 must not become a hundred queries a
///     second against a telco that rate-limits.
///   * **Fifteen minutes of silence is `indeterminate`**, not `failed`. The
///     money may have moved. It goes to a queue with a human behind it rather
///     than to a screen telling somebody their payment failed.
final class PaymentPoller {
  const PaymentPoller({
    required PaymentStore payments,
    required PayForBooking pay,
    Clock clock = const SystemClock(),
  }) : _payments = payments,
       _pay = pay,
       _clock = clock;

  final PaymentStore _payments;
  final PayForBooking _pay;
  final Clock _clock;

  Future<SweepResult> poll({int limit = 100}) async {
    final inFlight = await _payments.inFlight(limit: limit);
    var resolved = 0;

    for (final intent in inFlight) {
      // Silence for long enough is its own answer. Left `pending` forever, an
      // intent is a customer in the dark and money nobody has attributed —
      // which is exactly what the reconciliation console exists to work
      // through (ADR-0005).
      if (_clock.now().difference(intent.createdAt) >=
          PaymentIntent.indeterminateAfter) {
        await _payments.recordOutcome(
          intentId: intent.id,
          state: PaymentState.indeterminate,
          source: 'reconciliation',
          raw: {
            'reason':
                'no terminal answer within '
                '${PaymentIntent.indeterminateAfter.inMinutes} minutes',
          },
        );
        await _payments.markPolled(intent.id);
        continue;
      }

      final after = await _pay.reconcile(
        intentId: intent.id,
        railId: intent.railId,
        railTransactionId: intent.railTransactionId,
      );

      // Marked polled whatever the answer, including none: an intent that
      // errors on every query must still move down the queue, or it starves
      // everything behind it.
      await _payments.markPolled(intent.id);

      if (after != null && after.state.isTerminal) resolved++;
    }

    return SweepResult(name: 'payments.resolved', affected: resolved);
  }
}
