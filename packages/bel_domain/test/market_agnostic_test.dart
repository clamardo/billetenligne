import 'package:bel_domain/bel_domain.dart';
// P2b: remove this ignore. `Money`, `Currency` and `HoldPolicy` reach here
// today through bel_domain's transitional re-export, so the analyser calls
// this import unnecessary — which is precisely the smell the re-export
// creates and the reason `15-platform-split.md` §6 deletes it in the next
// slice. The import is written as it will be correct, not as it currently
// resolves.
// ignore: unnecessary_import
import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

/// The transport half of "adding a country is data plus an adapter".
///
/// The platform half lives in `bel_platform/test/market_test.dart`, which
/// stands up a complete second market (the DRC) in test code alone and proves
/// every country-dependent behaviour still works against it. These two tests
/// were part of that group until the platform split, and they had to leave:
/// they assert something about `SeatLayout`, `BookingRef` and the refund
/// engine, none of which `bel_platform` can see — and after ADR-0027 that is
/// the point rather than a gap.
///
/// Neither test needs the DRC `Market` const it used to borrow. One needed a
/// service fee in CDF, which is a `Money`, and the other needed nothing at
/// all. That they can be stated without a market is itself the claim.
void main() {
  group('adding a country touches no transport code', () {
    test('policy quoting is market-agnostic', () {
      // The refund engine never asks which country it is in — it only ever
      // sees Money, and Money already knows its currency.
      final departure = DateTime.utc(2026, 9, 1, 8);
      final quote = quoteRefund(
        faceValue: const Money(45000, Currency.cdf),
        // The DRC market's flat per-seat fee. Written as a literal rather
        // than read off a Market, because needing one to ask this question
        // would be the coupling this test exists to deny.
        serviceFee: const Money(300, Currency.cdf),
        departsAt: departure,
        now: departure.subtract(const Duration(days: 2)),
        policy: RefundPolicy.souple(),
      ).valueOrNull!;

      expect(quote.refundable, const Money(45000, Currency.cdf));
      expect(quote.refundable.currency, Currency.cdf);
    });

    test('seat layouts, refs and holds carry no country assumption', () {
      final layout = SeatLayout.busStandard49();
      expect(layout.capacity, 49);

      final ref = BookingRef.parse('7QK4M2');
      expect(ref.isOk, isTrue);

      const policy = HoldPolicy.standard;
      expect(policy.isValid, isTrue);
    });
  });
}
