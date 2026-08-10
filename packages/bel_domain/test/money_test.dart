import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Money — XAF is zero-decimal', () {
    test('9 000 XAF is 9000 minor units, not 900 000', () {
      const fare = Money.xaf(9000);
      expect(fare.minor, 9000);
      expect(fare.currency.exponent, 0);
    });

    test('formats fr with narrow no-break groups and trailing symbol', () {
      // Written as escapes on purpose: an invisible U+202F in a test file is
      // how "it looks identical but fails" bugs are born.
      const nn = Money.narrowNbsp; // U+202F between thousands
      const nb = Money.nbsp; // U+00A0 before the symbol
      expect(const Money.xaf(9000).format(locale: 'fr'), '9${nn}000${nb}FCFA');
      expect(
        const Money.xaf(1234567).format(locale: 'fr'),
        '1${nn}234${nn}567${nb}FCFA',
      );
    });

    test('formats en with comma groups and leading code', () {
      expect(const Money.xaf(9000).format(locale: 'en'), 'XAF 9,000');
    });

    test('handles a two-decimal currency correctly', () {
      const price = Money(9000, Currency.eur);
      expect(price.format(locale: 'fr'), '90,00${Money.nbsp}€');
      expect(price.format(locale: 'en'), 'EUR 90.00');
    });

    test('negative amounts use a real minus sign, not a hyphen', () {
      expect(
        const Money.xaf(-500).format(locale: 'fr'),
        '\u2212500${Money.nbsp}FCFA',
      );
    });
  });

  group('Money — arithmetic', () {
    test('adds and subtracts within a currency', () {
      expect(
        const Money.xaf(9000) + const Money.xaf(300),
        const Money.xaf(9300),
      );
      expect(
        const Money.xaf(9300) - const Money.xaf(300),
        const Money.xaf(9000),
      );
    });

    test('refuses to mix currencies', () {
      expect(
        () => const Money.xaf(9000) + const Money(100, Currency.usd),
        throwsArgumentError,
      );
    });

    test('percentBps keeps commission out of floating point', () {
      // 5% commission on a 9 000 XAF fare.
      expect(const Money.xaf(9000).percentBps(500), const Money.xaf(450));
      // 90% refund tier.
      expect(const Money.xaf(9000).percentBps(9000), const Money.xaf(8100));
    });

    test('clampToZero never lets a fee produce a negative refund', () {
      expect(const Money.xaf(-200).clampToZero(), const Money.xaf(0));
    });
  });

  group('Money.allocate — no rounding dust', () {
    test('splits exactly, remainder to the largest fractions', () {
      // The 04-payments.md worked example: 9 300 split into
      // operator payable / commission / service fee.
      final parts = const Money.xaf(9300).allocate([8550, 450, 300]);
      expect(parts.fold<int>(0, (a, m) => a + m.minor), 9300);
    });

    test('an awkward three-way split still sums exactly', () {
      final parts = const Money.xaf(10000).allocate([1, 1, 1]);
      expect(parts.map((m) => m.minor).toList(), [3334, 3333, 3333]);
      expect(parts.fold<int>(0, (a, m) => a + m.minor), 10000);
    });

    test('property: any split of any amount sums back to the original', () {
      for (var amount = 0; amount < 2000; amount += 7) {
        for (final weights in [
          [1, 1],
          [1, 2, 3],
          [5, 3, 1, 1],
          [100, 1],
        ]) {
          final parts = Money.xaf(amount).allocate(weights);
          expect(
            parts.fold<int>(0, (a, m) => a + m.minor),
            amount,
            reason: 'amount=$amount weights=$weights',
          );
        }
      }
    });
  });

  _commissionTerms();
}

void _commissionTerms() {
  group('CommissionTerm', () {
    test('is a term of one operator contract, in basis points', () {
      // 7.5% on a 12 000 XAF fare. The number comes from a contract, so the
      // type has to express what a contract can say — and contracts say
      // "seven and a half percent", not "0.075".
      expect(
        CommissionTerm(750).on(const Money.xaf(12000)),
        const Money.xaf(900),
      );
      expect(CommissionTerm(750).display, '7.5%');
      expect(CommissionTerm.seed.display, '5%');
      expect(CommissionTerm(1225).display, '12.25%');
    });

    test('cash carries none, and that is a value rather than a null', () {
      expect(
        CommissionTerm.none.on(const Money.xaf(12000)),
        Money.zero(Currency.xaf),
      );
    });

    test('refuses a rate the database CHECK would refuse', () {
      // `operators_commission_sane` caps at 3000 bps. Two places enforcing
      // two different ceilings is how a row gets written that the ledger then
      // cannot post.
      expect(() => CommissionTerm(3001), throwsArgumentError);
      expect(() => CommissionTerm(-1), throwsArgumentError);
      expect(CommissionTerm(3000).display, '30%');
    });
  });
}
