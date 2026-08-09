import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  final departure = DateTime.utc(2026, 8, 15, 6);
  const fare = Money.xaf(9000);
  const serviceFee = Money.xaf(300);

  RefundQuote quoteOrFail(Result<RefundQuote, RefundFailure> r) {
    expect(r.isOk, isTrue, reason: 'expected a quote, got ${r.failureOrNull}');
    return r.valueOrNull!;
  }

  group('quoteRefund — the function both the app and the server call', () {
    test('inside the free window, the traveller gets the full fare back', () {
      final quote = quoteOrFail(
        quoteRefund(
          faceValue: fare,
          serviceFee: serviceFee,
          departsAt: departure,
          now: departure.subtract(const Duration(days: 3)),
          policy: RefundPolicy.souple(),
        ),
      );

      expect(quote.refundable, const Money.xaf(9000));
      // Our service fee is not refundable by default.
      expect(quote.retained, const Money.xaf(300));
      expect(quote.rateBps, 10000);
      expect(quote.involuntary, isFalse);
    });

    test('the middle tier refunds half', () {
      final quote = quoteOrFail(
        quoteRefund(
          faceValue: fare,
          serviceFee: serviceFee,
          departsAt: departure,
          now: departure.subtract(const Duration(hours: 6)),
          policy: RefundPolicy.souple(),
        ),
      );

      expect(quote.refundable, const Money.xaf(4500));
      expect(quote.rateBps, 5000);
    });

    test('below the last tier there is no refund at all', () {
      final result = quoteRefund(
        faceValue: fare,
        serviceFee: serviceFee,
        departsAt: departure,
        now: departure.subtract(const Duration(minutes: 30)),
        policy: RefundPolicy.souple(),
      );

      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isA<OutsideRefundWindow>());
      expect(result.failureOrNull!.messageKey, 'errors.refund.outside_window');
    });

    test('the strict preset never refunds', () {
      final result = quoteRefund(
        faceValue: fare,
        serviceFee: serviceFee,
        departsAt: departure,
        now: departure.subtract(const Duration(days: 30)),
        policy: RefundPolicy.strict(),
      );
      expect(result.failureOrNull, isA<OutsideRefundWindow>());
    });

    test('a flat admin fee comes off the refund, never below zero', () {
      const policy = RefundPolicy(
        id: 'p',
        version: 1,
        tiers: [
          RefundTier(
            minLeadTime: Duration(hours: 24),
            rateBps: 10000,
            flatFeeMinor: 500,
          ),
        ],
      );

      final quote = quoteOrFail(
        quoteRefund(
          faceValue: fare,
          serviceFee: serviceFee,
          departsAt: departure,
          now: departure.subtract(const Duration(days: 2)),
          policy: policy,
        ),
      );

      expect(quote.refundable, const Money.xaf(8500));
      expect(quote.retained, const Money.xaf(800));
    });

    test('a non-refundable fare code is rejected by name', () {
      final result = quoteRefund(
        faceValue: fare,
        serviceFee: serviceFee,
        departsAt: departure,
        now: departure.subtract(const Duration(days: 10)),
        policy: const RefundPolicy(
          id: 'p',
          version: 1,
          tiers: [RefundTier(minLeadTime: Duration.zero, rateBps: 10000)],
          nonRefundableFareCodes: {'promo'},
        ),
        fareCode: 'promo',
      );

      expect(result.failureOrNull, isA<FareNotRefundable>());
    });

    test('after departure there is nothing to quote', () {
      final result = quoteRefund(
        faceValue: fare,
        serviceFee: serviceFee,
        departsAt: departure,
        now: departure.add(const Duration(minutes: 1)),
        policy: RefundPolicy.souple(),
      );
      expect(result.failureOrNull, isA<AlreadyDeparted>());
    });
  });

  group('platform floor — an operator cannot configure its way out', () {
    test(
      'operator-caused disruption refunds everything, even under strict',
      () {
        final quote = quoteOrFail(
          quoteRefund(
            faceValue: fare,
            serviceFee: serviceFee,
            departsAt: departure,
            now: departure.subtract(const Duration(minutes: 10)),
            policy: RefundPolicy.strict(),
            operatorCaused: true,
          ),
        );

        // Full fare AND our service fee, to source, with no fee retained.
        expect(quote.refundable, const Money.xaf(9300));
        expect(quote.retained, const Money.xaf(0));
        expect(quote.destination, RefundDestination.source);
        expect(quote.involuntary, isTrue);
      },
    );

    test('the floor applies even inside the no-refund window', () {
      final quote = quoteOrFail(
        quoteRefund(
          faceValue: fare,
          serviceFee: serviceFee,
          departsAt: departure,
          now: departure.subtract(const Duration(minutes: 1)),
          policy: RefundPolicy.standard(),
          operatorCaused: true,
        ),
      );
      expect(quote.refundable, const Money.xaf(9300));
    });
  });

  group('invariants', () {
    test('a refund never exceeds what was paid, across the whole timeline', () {
      const paid = Money.xaf(9300);
      for (final policy in [
        RefundPolicy.souple(),
        RefundPolicy.standard(),
        RefundPolicy.strict(),
      ]) {
        for (var hours = 1; hours < 240; hours++) {
          final result = quoteRefund(
            faceValue: fare,
            serviceFee: serviceFee,
            departsAt: departure,
            now: departure.subtract(Duration(hours: hours)),
            policy: policy,
          );
          final quote = result.valueOrNull;
          if (quote == null) continue;
          expect(
            quote.refundable <= paid,
            isTrue,
            reason: 'policy=${policy.id} lead=${hours}h',
          );
          expect(quote.refundable.isNegative, isFalse);
          expect(quote.refundable + quote.retained, paid);
        }
      }
    });
  });
}
