import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// `08-disruption.md` §5 — the handshake at the gare, written down once.
void main() {
  group('a corridor', () {
    test('is the same road in either direction', () {
      expect(Corridor('BZV', 'PNR'), Corridor('PNR', 'BZV'));
      expect(Corridor('BZV', 'PNR').key, Corridor('PNR', 'BZV').key);
    });

    test('has one spelling, so an index can be built on it', () {
      expect(Corridor('pnr', ' bzv ').key, 'BZV~PNR');
      expect(Corridor.parse('PNR~BZV').key, 'BZV~PNR');
    });

    test('refuses a road that goes nowhere', () {
      expect(() => Corridor('BZV', 'BZV'), throwsArgumentError);
      expect(() => Corridor('BZV', ''), throwsArgumentError);
    });

    test('covers a journey either way round', () {
      final c = Corridor('BZV', 'PNR');
      expect(c.covers('BZV', 'PNR'), isTrue);
      expect(c.covers('PNR', 'BZV'), isTrue);
      expect(c.covers('BZV', 'DOL'), isFalse);
    });
  });

  group('an agreement', () {
    ProtectionAgreement agreement({
      ProtectionAgreementState state = ProtectionAgreementState.active,
      bool reciprocal = true,
      int discountBps = 1500,
      int? cap,
      int? autoAbove,
      String proposedBy = 'op-ocean',
    }) => ProtectionAgreement(
      id: 'agr-1',
      operatorA: 'op-bony',
      operatorB: 'op-ocean',
      corridors: [Corridor('BZV', 'PNR'), Corridor('BZV', 'DOL')],
      state: state,
      proposedBy: proposedBy,
      reciprocal: reciprocal,
      rebillDiscountBps: discountBps,
      monthlyCapSeats: cap,
      autoAcceptWhenSpareAbove: autoAbove,
    );

    test('a pair has one spelling whichever way it is written', () {
      expect(
        ProtectionAgreement.partiesOf('op-ocean', 'op-bony'),
        ProtectionAgreement.partiesOf('op-bony', 'op-ocean'),
      );
    });

    test('rebills the public fare less the agreed discount', () {
      // §5: "tarif public − 15%". The seat sells at 9 000; the sending
      // operator is billed 7 650, not what their passenger paid.
      expect(
        agreement().rebillPerSeat(const Money.xaf(9000)),
        const Money.xaf(7650),
      );
    });

    test('a discount of nothing bills the public fare', () {
      expect(
        agreement(discountBps: 0).rebillPerSeat(const Money.xaf(9000)),
        const Money.xaf(9000),
      );
    });

    test('protects nobody until the other party has accepted it', () {
      final proposed = agreement(state: ProtectionAgreementState.proposed);
      expect(proposed.allowsRequestFrom('op-bony'), isFalse);
      expect(
        refuseProtection(
          agreement: proposed,
          requester: 'op-bony',
          origin: 'BZV',
          destination: 'PNR',
          seats: 10,
          seatsUsedThisMonth: 0,
        ),
        isA<NoAgreement>(),
      );
    });

    test('one-way protects the party that did not write the terms', () {
      // An operator does not write terms obliging their counterparty to
      // rescue them and also reserve the right to be the rescuer.
      final oneWay = agreement(reciprocal: false, proposedBy: 'op-ocean');
      expect(oneWay.allowsRequestFrom('op-ocean'), isTrue);
      expect(oneWay.allowsRequestFrom('op-bony'), isFalse);
    });

    test('reciprocal lets either side call on the other', () {
      final both = agreement();
      expect(both.allowsRequestFrom('op-ocean'), isTrue);
      expect(both.allowsRequestFrom('op-bony'), isTrue);
    });
  });

  group('refusing a request', () {
    ProtectionAgreement live({int? cap}) => ProtectionAgreement(
      id: 'agr-1',
      operatorA: 'op-bony',
      operatorB: 'op-ocean',
      corridors: [Corridor('BZV', 'PNR')],
      state: ProtectionAgreementState.active,
      proposedBy: 'op-ocean',
      monthlyCapSeats: cap,
    );

    ProtectionRefusal? ask({
      ProtectionAgreement? agreement,
      String requester = 'op-ocean',
      String origin = 'BZV',
      String destination = 'PNR',
      int seats = 10,
      int used = 0,
    }) => refuseProtection(
      agreement: agreement,
      requester: requester,
      origin: origin,
      destination: destination,
      seats: seats,
      seatsUsedThisMonth: used,
    );

    test('with nobody to ask', () {
      expect(ask(agreement: null), isA<NoAgreement>());
    });

    test('on a road the agreement does not cover', () {
      final refusal = ask(agreement: live(), destination: 'OYO');
      expect(refusal, isA<CorridorNotCovered>());
      // Named, so the console can say which road rather than "not covered".
      expect((refusal! as CorridorNotCovered).corridor, 'BZV~OYO');
    });

    test('from an operator who is not a party to it', () {
      expect(ask(agreement: live(), requester: 'op-other'), isA<NoAgreement>());
    });

    test('past the monthly ceiling, and says where it stands', () {
      final refusal = ask(agreement: live(cap: 40), seats: 12, used: 31);
      expect(refusal, isA<MonthlyCapReached>());
      final cap = refusal! as MonthlyCapReached;
      expect(cap.cap, 40);
      expect(cap.used, 31);
      expect(cap.params, {'cap': 40, 'used': 31});
    });

    test('but not one that exactly reaches the ceiling', () {
      // 31 used and 9 asked for is 40, which is the plafond, not past it.
      expect(ask(agreement: live(cap: 40), seats: 9, used: 31), isNull);
    });

    test('and allows a covered request with room left', () {
      expect(ask(agreement: live(cap: 40), seats: 31), isNull);
    });
  });

  group('accepting automatically', () {
    ProtectionAgreement withThreshold(int? above) => ProtectionAgreement(
      id: 'agr-1',
      operatorA: 'op-bony',
      operatorB: 'op-ocean',
      corridors: [Corridor('BZV', 'PNR')],
      state: ProtectionAgreementState.active,
      proposedBy: 'op-ocean',
      autoAcceptWhenSpareAbove: above,
    );

    test('never, unless the receiving operator asked for it', () {
      expect(acceptsAutomatically(withThreshold(null), 50), isFalse);
    });

    test('when the request barely dents the coach', () {
      expect(acceptsAutomatically(withThreshold(10), 24), isTrue);
    });

    test('and not when it would fill it', () {
      // A request that leaves ten seats or fewer is a decision somebody wants
      // to make themselves.
      expect(acceptsAutomatically(withThreshold(10), 10), isFalse);
      expect(acceptsAutomatically(withThreshold(10), 0), isFalse);
    });
  });

  group('the settlement', () {
    test('moves one payable to the other, and balances', () {
      final posted = protectionSettled(
        sendingOperatorId: 'op-ocean',
        receivingOperatorId: 'op-bony',
        amount: const Money.xaf(279000),
        reference: 'PR-4471',
      );

      final txn = posted.valueOrNull!;
      expect(txn.entries, hasLength(2));
      // `balanced` is the only constructor, so a returned transaction is one
      // Postgres will accept at COMMIT.
      expect(posted.valueOrNull, isNotNull);

      final debit = txn.entries.firstWhere(
        (e) => e.direction == LedgerDirection.debit,
      );
      final credit = txn.entries.firstWhere(
        (e) => e.direction == LedgerDirection.credit,
      );
      expect(debit.account, 'payable:operator:op-ocean');
      expect(credit.account, 'payable:operator:op-bony');
      expect(debit.amount, const Money.xaf(279000));
    });

    test('takes no commission — it is not a sale', () {
      final txn = protectionSettled(
        sendingOperatorId: 'op-ocean',
        receivingOperatorId: 'op-bony',
        amount: const Money.xaf(279000),
        reference: 'PR-4471',
      ).valueOrNull!;

      expect(
        txn.entries.where((e) => e.account.startsWith('revenue:')),
        isEmpty,
        reason: 'taxing a rescue would kill the behaviour we want',
      );
      expect(
        txn.entries.where((e) => e.account.startsWith('bank:')),
        isEmpty,
        reason: 'no cash moves — it nets into the next payout run',
      );
    });

    test('refuses to settle with itself', () {
      expect(
        protectionSettled(
          sendingOperatorId: 'op-ocean',
          receivingOperatorId: 'op-ocean',
          amount: const Money.xaf(1000),
          reference: 'PR-1',
        ).failureOrNull,
        isA<SameOperator>(),
      );
    });

    test('refuses a posting of nothing', () {
      expect(
        protectionSettled(
          sendingOperatorId: 'op-ocean',
          receivingOperatorId: 'op-bony',
          amount: const Money.xaf(0),
          reference: 'PR-1',
        ).failureOrNull,
        isA<NothingToSettle>(),
      );
    });
  });
}
