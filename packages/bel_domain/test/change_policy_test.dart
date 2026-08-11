import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 10, 6);

  Result<ChangeQuote, ChangeRefusal> quote({
    int paid = 9000,
    int fresh = 9000,
    Duration lead = const Duration(days: 3),
    Duration targetLead = const Duration(days: 4),
    ChangePolicy policy = ChangePolicy.standard,
    bool involuntary = false,
  }) => quoteChange(
    paidFare: Money(paid, Currency.xaf),
    newFare: Money(fresh, Currency.xaf),
    departsAt: now.add(lead),
    targetDepartsAt: now.add(targetLead),
    now: now,
    policy: policy,
    involuntary: involuntary,
  );

  group('the three bands D-08 states', () {
    test('a day out and it is free', () {
      final q = quote(lead: const Duration(hours: 25)).valueOrNull!;

      expect(q.fee, const Money.xaf(0));
      expect(q.isFree, isTrue);
    });

    test('exactly at the free window is still free', () {
      // The boundary is inclusive on purpose: somebody reading "24 h avant"
      // and acting at 24 h exactly must not be charged for arithmetic.
      final q = quote(lead: const Duration(hours: 24)).valueOrNull!;

      expect(q.fee, const Money.xaf(0));
    });

    test('inside the window it costs the operator’s percentage', () {
      final q = quote(lead: const Duration(hours: 6)).valueOrNull!;

      // 10% of the fare already paid, not of the new one — the fee is for
      // changing, and a dearer coach is charged separately as a difference.
      expect(q.fee, const Money.xaf(900));
      expect(q.owed, const Money.xaf(900));
    });

    test('the percentage is the operator’s, not a constant', () {
      final q = quote(
        lead: const Duration(hours: 6),
        policy: const ChangePolicy(feeBps: 2500),
      ).valueOrNull!;

      expect(q.fee, const Money.xaf(2250));
    });

    test('an operator can charge nothing at all, ever', () {
      final q = quote(
        lead: const Duration(hours: 6),
        policy: const ChangePolicy(feeBps: 0),
      ).valueOrNull!;

      expect(q.isFree, isTrue);
    });

    test('inside the cutoff the answer is no, with the hour in it', () {
      final refused = quote(lead: const Duration(minutes: 90));

      expect(
        refused,
        isA<Err<ChangeQuote, ChangeRefusal>>()
            .having((e) => e.failure.code, 'code', 'change.too_late')
            .having((e) => e.failure.params['hours'], 'hours', 2),
      );
    });

    test('the cutoff boundary is inclusive', () {
      expect(quote(lead: const Duration(hours: 2)).valueOrNull, isNotNull);
    });
  });

  group('the fare difference', () {
    test('a dearer coach is charged, and the fee is on top', () {
      final q = quote(
        fresh: 10500,
        lead: const Duration(hours: 6),
      ).valueOrNull!;

      expect(q.fareDifference, const Money.xaf(1500));
      expect(q.owed, const Money.xaf(2400));
    });

    test('a dearer coach with enough notice is only the difference', () {
      final q = quote(fresh: 10500, lead: const Duration(days: 3)).valueOrNull!;

      expect(q.fee, const Money.xaf(0));
      expect(q.owed, const Money.xaf(1500));
    });

    test('a cheaper coach gives nothing back, and never goes negative', () {
      // Stated on the row before anybody taps. Refunding it would mean a
      // disbursement we cannot make, or a counter claim worth less than the
      // counter time it consumes — and discovering either after the tap is
      // worse than reading the sentence before it.
      final q = quote(fresh: 7000).valueOrNull!;

      expect(q.fareDifference, const Money.xaf(0));
      expect(q.owed, const Money.xaf(0));
    });
  });

  group('what it refuses', () {
    test('a coach that has already left', () {
      expect(
        quote(lead: const Duration(hours: -1)),
        isA<Err<ChangeQuote, ChangeRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'change.already_departed',
        ),
      );
    });

    test('a target in the past', () {
      expect(
        quote(targetLead: const Duration(hours: -1)),
        isA<Err<ChangeQuote, ChangeRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'change.into_the_past',
        ),
      );
    });

    test('a departed coach outranks the cutoff', () {
      // Both are true. "Ce car est parti" is the one somebody can act on.
      expect(
        quote(lead: const Duration(minutes: -5)),
        isA<Err<ChangeQuote, ChangeRefusal>>().having(
          (e) => e.failure.code,
          'code',
          'change.already_departed',
        ),
      );
    });
  });

  group('the operator’s own failure', () {
    test('is free, inside every cutoff there is', () {
      // A passenger whose coach broke down at 03:00 is inside every window an
      // operator could write. Charging them the cutoff would be charging them
      // for the breakdown.
      final q = quote(
        lead: const Duration(minutes: 20),
        fresh: 12000,
        involuntary: true,
      ).valueOrNull!;

      expect(q.isFree, isTrue);
      expect(q.fareDifference, const Money.xaf(0));
      expect(q.involuntary, isTrue);
    });

    test('but a coach that has gone is still gone', () {
      expect(
        quote(lead: const Duration(hours: -1), involuntary: true).valueOrNull,
        isNull,
      );
    });
  });

  group('money that is owed', () {
    test('a prompt already on a handset refuses a second order', () {
      // The seats a waiting order holds cannot be let go while money may be
      // about to land on them: a capture arriving after the release would pay
      // for a seat somebody else is sitting in.
      expect(const ChangePaymentInFlight().code, 'change.payment_in_flight');
    });

    test('the refusal carries the amount, so the screen can name it', () {
      const refusal = ChangeMustBePaid(2400, 'XAF');

      // A traveller sent to a counter has to know what to bring. "Payez la
      // différence" without a figure is a second trip to the counter.
      expect(refusal.code, 'change.must_be_paid');
      expect(refusal.params['owedMinor'], 2400);
      expect(refusal.params['currency'], 'XAF');
    });
  });

  group('terms that can be evaluated', () {
    test('a cutoff longer than the free window is malformed', () {
      // The fee band would not exist, every change inside it would be refused
      // as too late, and nobody would notice until the month was counted.
      expect(
        const ChangePolicy(
          freeBefore: Duration(hours: 2),
          cutoff: Duration(hours: 24),
        ).isWellFormed,
        isFalse,
      );
    });

    test('a rate above 100% is malformed', () {
      expect(const ChangePolicy(feeBps: 10001).isWellFormed, isFalse);
    });

    test('the stated defaults are well formed', () {
      expect(ChangePolicy.standard.isWellFormed, isTrue);
    });
  });

  group('the terms as sentences', () {
    test('they carry the numbers, not prose', () {
      final lines = ChangePolicy.standard.describe();

      expect(lines, contains('policy.change.free|24'));
      expect(lines, contains('policy.change.fee|2|24|10'));
      expect(lines, contains('policy.change.cutoff|2'));
      // The floor, always last and never configurable away.
      expect(lines.last, 'policy.change.involuntaryFree');
    });

    test('an operator charging nothing says so rather than "0 %"', () {
      final lines = const ChangePolicy(feeBps: 0).describe();

      expect(lines, contains('policy.change.noFee|2|24'));
      expect(lines.any((l) => l.startsWith('policy.change.fee|')), isFalse);
    });
  });
}
