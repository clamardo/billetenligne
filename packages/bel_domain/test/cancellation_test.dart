import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 10, 6);
  final tomorrow = DateTime.utc(2026, 8, 11, 6);

  Result<CancellationKind, CancellationRefusal> kind({
    BookingStanding standing = BookingStanding.paid,
    bool paidInCash = false,
    RefundDestination destination = RefundDestination.source,
    DateTime? departsAt,
    bool paymentInFlight = false,
  }) => cancellationKind(
    standing: standing,
    paidInCash: paidInCash,
    destination: destination,
    departsAt: departsAt ?? tomorrow,
    now: now,
    paymentInFlight: paymentInFlight,
  );

  group('what cancelling does', () {
    test('an unpaid reservation is released, not refunded', () {
      // The common case, and the one worth getting out of the way first: a
      // payment code that was never used owes nobody anything, and calling it
      // a refund would put a claim code on a screen for 0 FCFA.
      expect(
        kind(standing: BookingStanding.awaitingPayment).valueOrNull,
        CancellationKind.release,
      );
    });

    test('an unpaid reservation is released whatever the policy says', () {
      expect(
        kind(
          standing: BookingStanding.awaitingPayment,
          destination: RefundDestination.creditNote,
        ).valueOrNull,
        CancellationKind.release,
      );
    });

    test('a wallet payment goes back the way it came', () {
      expect(kind().valueOrNull, CancellationKind.toSource);
    });

    test('a counter policy ends at a counter', () {
      expect(
        kind(destination: RefundDestination.agencyCash).valueOrNull,
        CancellationKind.claimAtCounter,
      );
    });

    test("the traveller's own choice is offered at a counter", () {
      // Somebody has to be asked which, and the app cannot ask at the moment
      // of cancelling — so it ends where every destination can be honoured.
      expect(
        kind(destination: RefundDestination.travellerChoice).valueOrNull,
        CancellationKind.claimAtCounter,
      );
    });

    test('cash paid at a counter comes back at a counter, whatever the '
        'policy field says', () {
      // The policy describes wallet and card journeys. A journey paid in
      // notes never had a source, and "back to source" for it is a sentence
      // that cannot be honoured by anybody.
      expect(
        kind(
          paidInCash: true,
          destination: RefundDestination.source,
        ).valueOrNull,
        CancellationKind.claimAtCounter,
      );
    });
  });

  group('what it refuses', () {
    test('a booking already cancelled has nothing left to cancel', () {
      expect(
        kind(standing: BookingStanding.gone),
        isA<Err<CancellationKind, CancellationRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'cancel.nothing_to_cancel',
        ),
      );
    });

    test('a departed coach is a conversation, not a button', () {
      expect(
        kind(departsAt: now.subtract(const Duration(minutes: 1))),
        isA<Err<CancellationKind, CancellationRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'cancel.coach_has_left',
        ),
      );
    });

    test('the moment of departure is already too late', () {
      // Not a strict inequality by accident: at 06:00 exactly the coach is
      // pulling out, and a refund granted at that second is a seat nobody
      // can resell.
      expect(kind(departsAt: now).valueOrNull, isNull);
    });

    test('a departed coach refuses even an unpaid reservation', () {
      expect(
        kind(
          standing: BookingStanding.awaitingPayment,
          departsAt: now.subtract(const Duration(hours: 1)),
        ).valueOrNull,
        isNull,
      );
    });

    test('a payment still in flight is not cancelled underneath', () {
      // Somebody is typing a PIN on a handset we cannot see. Releasing the
      // seats now and capturing the money a second later is the one outcome
      // nobody can undo from either end.
      expect(
        kind(standing: BookingStanding.awaitingPayment, paymentInFlight: true),
        isA<Err<CancellationKind, CancellationRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'cancel.payment_in_flight',
        ),
      );
    });

    test('a departed coach outranks a payment in flight', () {
      // Both are true; only one of them tells somebody what to do next.
      expect(
        kind(
          paymentInFlight: true,
          departsAt: now.subtract(const Duration(hours: 1)),
        ),
        isA<Err<CancellationKind, CancellationRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'cancel.coach_has_left',
        ),
      );
    });

    test('a credit note is the agency, not the app', () {
      // We do not issue credit notes. Turning one into cash would be handing
      // out money on terms the operator never agreed to.
      expect(
        kind(destination: RefundDestination.creditNote),
        isA<Err<CancellationKind, CancellationRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'cancel.needs_the_agency',
        ),
      );
    });
  });

  group('warning that nothing comes back', () {
    Result<RefundQuote, RefundFailure> quoteAt(Duration lead, RefundPolicy p) =>
        quoteRefund(
          faceValue: Money(900000, Currency.xaf),
          serviceFee: Money(30000, Currency.xaf),
          departsAt: now.add(lead),
          now: now,
          policy: p,
        );

    test('a policy that refuses is a warning, not a closed door', () {
      final quote = quoteAt(const Duration(hours: 1), RefundPolicy.souple());

      expect(quote.valueOrNull, isNull);
      expect(cancellingCostsEverything(quote), isTrue);
      // And the cancellation itself is still allowed: somebody who knows they
      // cannot travel frees the seat rather than no-showing.
      expect(
        kind(departsAt: now.add(const Duration(hours: 1))).valueOrNull,
        isNotNull,
      );
    });

    test('a policy with no tiers at all warns', () {
      expect(
        cancellingCostsEverything(
          quoteAt(const Duration(days: 9), RefundPolicy.strict()),
        ),
        isTrue,
      );
    });

    test('a quote that gives something back does not warn', () {
      expect(
        cancellingCostsEverything(
          quoteAt(const Duration(hours: 30), RefundPolicy.souple()),
        ),
        isFalse,
      );
    });

    test('a quote that rounds to nothing warns', () {
      // 5% of 5 FCFA is nought, and a screen that shows "0 FCFA" beside a
      // confirm button has told nobody anything.
      final quote = quoteRefund(
        faceValue: Money(5, Currency.xaf),
        serviceFee: Money(0, Currency.xaf),
        departsAt: now.add(const Duration(hours: 3)),
        now: now,
        policy: const RefundPolicy(
          id: 'p',
          version: 1,
          tiers: [RefundTier(minLeadTime: Duration(hours: 2), rateBps: 500)],
        ),
      );

      expect(quote.valueOrNull?.refundable.minor, 0);
      expect(cancellingCostsEverything(quote), isTrue);
    });
  });
}
