import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_traveller/src/application/payment_flow.dart';
import 'package:flutter_test/flutter_test.dart';

import 'booking_flow_test.dart' show ScriptedGatewayFactory;

void main() {
  late ScriptedGatewayFactory gateway;
  late PaymentFlow flow;

  setUp(() {
    gateway = ScriptedGatewayFactory();
    flow = PaymentFlow(gateway: gateway);
  });

  Future<void> reachMethod() => flow.start('bk-1');

  group('choosing how to pay', () {
    test('preselects the wallet the traveller own number belongs to', () async {
      await reachMethod();

      final step = flow.step as ChoosingMethod;
      // The majority case then costs no taps at all. `242 06…` is MTN.
      expect(step.selected!.railId, 'cg.mtn_momo');
      expect(step.payerMsisdn, '242061234567');
      expect(step.payingFromOwnNumber, isTrue);
    });

    test('typing another carrier number re-selects that wallet', () async {
      await reachMethod();

      // 05 is Airtel. Somebody who replaces the prefilled MTN number should
      // not be sent into a wrong-carrier refusal they could have been spared.
      flow.setPayerNumber('242051234567');

      final step = flow.step as ChoosingMethod;
      expect(step.selected!.railId, 'cg.airtel_money');
      expect(step.payingFromOwnNumber, isFalse);
    });

    test('paying from somebody else number is allowed and flagged', () async {
      await reachMethod();
      flow.setPayerNumber('242069999999');

      final step = flow.step as ChoosingMethod;
      // Allowed, because it is the commonest way a ticket gets paid for in
      // this market — and flagged, so the screen can say so out loud.
      expect(step.payingFromOwnNumber, isFalse);
      expect(step.selected!.railId, 'cg.mtn_momo');
    });

    test('review does nothing until the number parses', () async {
      await reachMethod();
      flow.setPayerNumber('12');
      flow.review();

      expect(flow.step, isA<ChoosingMethod>());
    });

    test('a failure to load options is shown, not a blank list', () async {
      gateway.optionsFailure = const NetworkUnreachable();
      await reachMethod();

      final step = flow.step as ChoosingMethod;
      expect(step.failure, isA<NetworkUnreachable>());
    });
  });

  group('confirming', () {
    test('shows where the money goes before anything is sent', () async {
      await reachMethod();
      flow.review();

      final step = flow.step as ConfirmingPayment;
      expect(step.option.collectionMsisdn, '242060000001');
      expect(step.option.collectionName, 'Ocean du Nord');
      expect(step.amount, const Money.xaf(12300));
      // Nothing has been sent. This screen is the last moment anybody can
      // notice they are paying the wrong number.
      expect(gateway.startedPayments, isEmpty);
    });

    test('paying pushes the prompt and waits', () async {
      await reachMethod();
      flow.review();
      await flow.pay();

      expect(gateway.startedPayments, hasLength(1));
      expect(gateway.startedPayments.single.railId, 'cg.mtn_momo');
      expect(gateway.startedPayments.single.payerMsisdn, '242061234567');
      // `pending`, not paid. The traveller has not typed a PIN.
      expect(flow.step, isA<AwaitingPin>());
    });

    test('a refusal at request time names the reason', () async {
      gateway.startPaymentFailure = const ServerRefused(
        422,
        ApiError(code: 'payment.insufficient_funds'),
      );
      await reachMethod();
      flow.review();
      await flow.pay();

      final step = flow.step as PaymentRefused;
      expect(step.intent.failureCode, 'payment.insufficient_funds');
      // Retryable and the seat is kept: they can top up and try again.
      expect(step.retryable, isTrue);
    });

    test('a retried attempt reuses the key until the server answers', () async {
      gateway.startPaymentFailure = const NetworkUnreachable();
      await reachMethod();
      flow.review();
      await flow.pay();

      gateway.startPaymentFailure = null;
      flow.review();
      await flow.pay();

      // Two PIN prompts on one handset is a person asked for their PIN twice
      // for one journey.
      expect(gateway.startedPayments, hasLength(2));
      expect(
        gateway.startedPayments.first.key,
        gateway.startedPayments.last.key,
      );
    });
  });

  group('waiting for the PIN', () {
    test('a capture becomes a receipt', () async {
      gateway.statusScript.add('captured');
      await reachMethod();
      flow.review();
      await flow.pay();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final step = flow.step as PaymentSucceeded;
      expect(step.intent.state, 'captured');
      expect(step.booking.ref, 'BEL-7QK4M2');
    });

    test('a decline becomes a refusal with its own code', () async {
      gateway.statusScript.add('failed');
      await reachMethod();
      flow.review();
      await flow.pay();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      final step = flow.step as PaymentRefused;
      expect(step.intent.failureCode, 'payment.wrong_pin');
      expect(step.retryable, isTrue);
    });

    test('indeterminate is not a failure screen', () async {
      gateway.statusScript.add('indeterminate');
      await reachMethod();
      flow.review();
      await flow.pay();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The money may have left their wallet. Calling that a failure is the
      // fastest way to lose somebody's trust.
      expect(flow.step, isA<PaymentUnresolved>());
      expect(flow.step, isNot(isA<PaymentRefused>()));
    });

    test('pending keeps waiting rather than giving up', () async {
      gateway.statusScript.addAll(['pending', 'pending', 'captured']);
      await reachMethod();
      flow.review();
      await flow.pay();

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(flow.step, isA<PaymentSucceeded>());
    });
  });

  tearDown(() => flow.dispose());
}
