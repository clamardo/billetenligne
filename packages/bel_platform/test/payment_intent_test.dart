import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 15, 5, 30);

  PaymentIntent fresh({PaymentState state = PaymentState.created}) =>
      PaymentIntent(
        id: 'pi_1',
        bookingId: 'bk_1',
        railId: 'cg.airtel_money',
        amount: const Money.xaf(9300),
        idempotencyKey: 'idem-abc',
        createdAt: t0,
        state: state,
        msisdn: '242061234567',
      );

  PaymentIntent advance(
    PaymentIntent i,
    PaymentState to, {
    PaymentFailureCode? code,
  }) {
    final r = i.transitionTo(to, now: t0, failureCode: code);
    expect(r.isOk, isTrue, reason: '${r.failureOrNull}');
    return r.valueOrNull!;
  }

  group('the happy path', () {
    test('created → pending → authorized → captured', () {
      var i = fresh();
      i = advance(i, PaymentState.pending);
      i = advance(i, PaymentState.authorized);
      i = advance(i, PaymentState.captured);

      expect(i.state.isSettled, isTrue);
      expect(i.issuesTicket, isTrue);
      expect(i.terminalAt, t0);
    });

    test('a rail that captures without a separate auth is supported', () {
      var i = advance(fresh(), PaymentState.pending);
      i = advance(i, PaymentState.captured);
      expect(i.issuesTicket, isTrue);
    });

    test('a ticket is issued in no other state', () {
      for (final s in PaymentState.values) {
        final i = fresh(state: s);
        expect(i.issuesTicket, s == PaymentState.captured, reason: s.name);
      }
    });
  });

  group('transitions are guarded', () {
    test('terminal states are terminal', () {
      for (final terminal in [
        PaymentState.captured,
        PaymentState.failed,
        PaymentState.expired,
        PaymentState.cancelled,
      ]) {
        final i = fresh(state: terminal);
        for (final next in PaymentState.values) {
          if (next == terminal) continue;
          expect(
            i.canTransitionTo(next),
            isFalse,
            reason: '${terminal.name} must not reach ${next.name}',
          );
        }
      }
    });

    test('a late callback cannot resurrect a settled intent', () {
      final captured = fresh(state: PaymentState.captured);
      final r = captured.transitionTo(PaymentState.failed, now: t0);

      expect(r.isErr, isTrue);
      expect(r.failureOrNull, isA<IllegalPaymentTransition>());
      expect(r.failureOrNull!.messageKey, 'errors.payment.illegal_transition');
    });

    test('you cannot skip straight from created to captured', () {
      expect(fresh().canTransitionTo(PaymentState.captured), isFalse);
    });

    test('indeterminate resolves only to captured or failed', () {
      final i = fresh(state: PaymentState.indeterminate);
      expect(i.canTransitionTo(PaymentState.captured), isTrue);
      expect(i.canTransitionTo(PaymentState.failed), isTrue);
      expect(i.canTransitionTo(PaymentState.pending), isFalse);
      expect(i.canTransitionTo(PaymentState.cancelled), isFalse);
    });
  });

  group('callback and poll race, and must not care who wins', () {
    test('re-applying the current state is a no-op, not an error', () {
      // A duplicate callback is normal traffic, not a fault.
      final captured = advance(
        advance(fresh(), PaymentState.pending),
        PaymentState.captured,
      );
      final again = captured.transitionTo(PaymentState.captured, now: t0);

      expect(again.isOk, isTrue);
      expect(again.valueOrNull!.state, PaymentState.captured);
    });

    test('applying capture twice yields an identical intent', () {
      final once = advance(
        advance(fresh(), PaymentState.pending),
        PaymentState.captured,
      );
      final twice = once
          .transitionTo(PaymentState.captured, now: t0)
          .valueOrNull!;

      expect(twice.state, once.state);
      expect(twice.terminalAt, once.terminalAt);
      expect(twice.amount, once.amount);
    });
  });

  group('polling', () {
    test('backs off 5, 10, 20, 40 then holds at 60 seconds', () {
      var i = advance(fresh(), PaymentState.pending);
      final delays = <int>[];
      for (var n = 0; n < 6; n++) {
        delays.add(i.nextPollDelay.inSeconds);
        i = i.recordPoll();
      }
      expect(delays, [5, 10, 20, 40, 60, 60]);
    });

    test('gives up to the reconciliation queue after 15 minutes', () {
      final i = advance(fresh(), PaymentState.pending);
      expect(i.shouldGiveUpAt(t0.add(const Duration(minutes: 14))), isFalse);
      expect(i.shouldGiveUpAt(t0.add(const Duration(minutes: 15))), isTrue);
    });

    test('a settled intent is never polled again', () {
      final captured = advance(
        advance(fresh(), PaymentState.pending),
        PaymentState.captured,
      );
      expect(
        captured.shouldGiveUpAt(t0.add(const Duration(hours: 2))),
        isFalse,
      );
      expect(captured.state.isInFlight, isFalse);
    });
  });

  group('failure taxonomy', () {
    test('every code has a distinct wire value and catalog key', () {
      final wires = PaymentFailureCode.values.map((c) => c.wire).toList();
      expect(wires.toSet(), hasLength(wires.length));
      for (final c in PaymentFailureCode.values) {
        expect(c.messageKey, startsWith('errors.'));
      }
    });

    test('recoverable failures keep the seat held', () {
      final i = advance(
        advance(fresh(), PaymentState.pending),
        PaymentState.failed,
        code: PaymentFailureCode.insufficientFunds,
      );
      expect(
        i.keepsHold,
        isTrue,
        reason: 'the traveller must be able to try another wallet',
      );
    });

    test('a lost hold is the one failure that does not keep the seat', () {
      final i = advance(
        advance(fresh(), PaymentState.pending),
        PaymentState.failed,
        code: PaymentFailureCode.holdExpiredDuringPayment,
      );
      expect(i.keepsHold, isFalse);
      expect(PaymentFailureCode.holdExpiredDuringPayment.retryable, isFalse);
    });

    test('a cancelled or expired attempt releases the seat', () {
      for (final s in [PaymentState.cancelled, PaymentState.expired]) {
        expect(fresh(state: s).keepsHold, isFalse, reason: s.name);
      }
    });
  });

  group('the timing invariant that stops a seat being sold twice', () {
    test('the hold always outlives the payment window', () {
      const p = HoldPolicy.standard;
      expect(p.isValid, isTrue);
      expect(p.ttl > p.paymentWindow, isTrue);
      expect(p.warnAt < p.paymentWindow, isTrue);
    });

    test('the reconciliation cutoff sits beyond the payment window', () {
      // Otherwise an intent would be declared indeterminate while the
      // traveller is still legitimately entering their PIN.
      expect(
        PaymentIntent.indeterminateAfter,
        greaterThan(HoldPolicy.standard.paymentWindow),
      );
    });

    test('an intent gives up before the hold it depends on expires', () {
      expect(
        PaymentIntent.indeterminateAfter,
        lessThanOrEqualTo(HoldPolicy.standard.ttl),
      );
    });
  });
}
