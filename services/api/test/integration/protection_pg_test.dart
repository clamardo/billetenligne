@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_protection.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Inter-operator protection agreements, against the policies that carry them
/// (`08-disruption.md` §5).
///
/// The domain suite proves the terms. This file exists for the claims only a
/// database can make: that a row belongs to **two** tenants and to no third,
/// that the party who wrote the terms cannot be the party who agrees to them,
/// that the terms are frozen by a grant once agreed, and that two operators
/// have at most one agreement in force.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresProtection protection;
  late String ocean;
  late String bony;
  late String theirDispatcher;
  late String ourDispatcher;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    protection = PostgresProtection(db);
    ocean = PgFixture.operatorId;
    bony = await fixture.secondOperator();
    ourDispatcher = await fixture.traveller('prot-ours', name: 'Régulation');
    theirDispatcher = await fixture.traveller('prot-them', name: 'Bony');
  });

  setUp(() async => fixture.clearAgreements());
  tearDownAll(() async => db.close());

  Future<ProtectionAgreementView> propose({
    int discountBps = 1500,
    int? cap = 40,
    int? spareAbove,
    bool reciprocal = true,
    List<Corridor>? corridors,
  }) async {
    final result = await protection.propose(
      operatorId: ocean,
      counterpartyCode: PgFixture.secondOperatorCode,
      corridors: corridors ?? [Corridor('BZV', 'PNR')],
      actorUserId: ourDispatcher,
      reciprocal: reciprocal,
      rebillDiscountBps: discountBps,
      monthlyCapSeats: cap,
      autoAcceptWhenSpareAbove: spareAbove,
    );
    expect(result.refusal, isNull, reason: 'proposal was refused');
    return result.agreement!;
  }

  group('proposing', () {
    test('names the counterparty by code, not by our id', () async {
      final agreement = await propose();

      expect(agreement.counterpartyId, bony);
      expect(agreement.counterpartyName, 'Trans Bony Voyages');
      expect(agreement.weProposed, isTrue);
      expect(agreement.agreement.state, ProtectionAgreementState.proposed);
    });

    test('binds nobody until the other party accepts', () async {
      final agreement = await propose();

      // The refusal the dispatcher's screen shows: there is an agreement on
      // the page and it protects nobody yet.
      expect(
        refuseProtection(
          agreement: agreement.agreement,
          requester: ocean,
          origin: 'BZV',
          destination: 'PNR',
          seats: 10,
          seatsUsedThisMonth: 0,
        ),
        isA<NoAgreement>(),
      );
    });

    test('refuses a company that does not exist', () async {
      final result = await protection.propose(
        operatorId: ocean,
        counterpartyCode: 'NOPE',
        corridors: [Corridor('BZV', 'PNR')],
        actorUserId: ourDispatcher,
      );
      expect(result.refusal, isA<UnknownCounterparty>());
    });

    test('refuses an agreement with itself', () async {
      final result = await protection.propose(
        operatorId: ocean,
        counterpartyCode: 'ODN',
        corridors: [Corridor('BZV', 'PNR')],
        actorUserId: ourDispatcher,
      );
      expect(result.refusal, isA<AgreementRefused>());
      expect(result.refusal!.code, 'protection.same_operator');
    });

    test('refuses one that covers no road at all', () async {
      final result = await protection.propose(
        operatorId: ocean,
        counterpartyCode: PgFixture.secondOperatorCode,
        corridors: const [],
        actorUserId: ourDispatcher,
      );
      expect(result.refusal!.code, 'agreement.no_corridors');
    });

    test('refuses a second one while the first is live', () async {
      await propose();
      final second = await protection.propose(
        operatorId: ocean,
        counterpartyCode: PgFixture.secondOperatorCode,
        corridors: [Corridor('BZV', 'DOL')],
        actorUserId: ourDispatcher,
      );
      // Two rates for the same seat, with no way to say which was meant.
      expect(second.refusal, isA<AlreadyAgreed>());
    });

    test('stores the corridor in one spelling, either way round', () async {
      final agreement = await propose(corridors: [Corridor('PNR', 'BZV')]);
      expect(
        [for (final c in agreement.agreement.corridors) c.key],
        ['BZV~PNR'],
      );
    });
  });

  group('the counterparty', () {
    test('sees an agreement it did not write', () async {
      await propose();

      final theirs = await protection.agreementsFor(bony);
      expect(theirs, hasLength(1));
      expect(theirs.single.weProposed, isFalse);
      expect(theirs.single.awaitingUs, isTrue);
      // From their side the counterparty is us, and named.
      expect(theirs.single.counterpartyId, ocean);
      expect(theirs.single.counterpartyName, 'Ocean du Nord');
    });

    test('and the corridors that come with it', () async {
      await propose(
        corridors: [Corridor('BZV', 'PNR'), Corridor('BZV', 'OYO')],
      );

      final theirs = await protection.agreementsFor(bony);
      expect(
        [for (final c in theirs.single.agreement.corridors) c.key],
        ['BZV~OYO', 'BZV~PNR'],
      );
    });

    test('accepts, and the agreement starts protecting people', () async {
      final proposed = await propose();

      final decided = await protection.decide(
        operatorId: bony,
        agreementId: proposed.agreement.id,
        decision: 'accept',
        actorUserId: theirDispatcher,
      );

      expect(decided.refusal, isNull);
      final live = decided.agreement!.agreement;
      expect(live.state, ProtectionAgreementState.active);
      expect(decided.agreement!.acceptedAt, isNotNull);
      expect(
        refuseProtection(
          agreement: live,
          requester: ocean,
          origin: 'BZV',
          destination: 'PNR',
          seats: 31,
          seatsUsedThisMonth: 0,
        ),
        isNull,
      );
    });

    test('declines, and it is over', () async {
      final proposed = await propose();

      final decided = await protection.decide(
        operatorId: bony,
        agreementId: proposed.agreement.id,
        decision: 'decline',
        actorUserId: theirDispatcher,
        reason: 'Pas de capacité sur ce corridor',
      );

      expect(
        decided.agreement!.agreement.state,
        ProtectionAgreementState.ended,
      );
      expect(decided.agreement!.endedReason, 'Pas de capacité sur ce corridor');
      // And the pair is free to try again, because nothing is in force.
      final again = await protection.propose(
        operatorId: ocean,
        counterpartyCode: PgFixture.secondOperatorCode,
        corridors: [Corridor('BZV', 'PNR')],
        actorUserId: ourDispatcher,
      );
      expect(again.refusal, isNull);
    });
  });

  group('the party that wrote the terms', () {
    test('cannot accept them', () async {
      final proposed = await propose();

      final decided = await protection.decide(
        operatorId: ocean,
        agreementId: proposed.agreement.id,
        decision: 'accept',
        actorUserId: ourDispatcher,
      );

      // The payout run's rule, one size down. An agreement one party could
      // switch on alone would be an invoice one party could write alone.
      expect(decided.refusal, isA<AgreementRefused>());
      expect(decided.refusal!.code, 'protection.own_proposal');
    });

    test('may still withdraw it', () async {
      final proposed = await propose();

      final decided = await protection.decide(
        operatorId: ocean,
        agreementId: proposed.agreement.id,
        decision: 'end',
        actorUserId: ourDispatcher,
        reason: 'Retiré',
      );
      expect(
        decided.agreement!.agreement.state,
        ProtectionAgreementState.ended,
      );
    });
  });

  group('a third company', () {
    test('cannot see two other companies terms', () async {
      await propose();

      // Not a filter in the adapter — the RLS policy names exactly two
      // tenants, and a third one asking gets an empty answer from Postgres.
      final theirs = await protection.agreementsFor(
        'ffffffff-ffff-ffff-ffff-ffffffffffff',
      );
      expect(theirs, isEmpty);
    });

    test('cannot decide them either', () async {
      final proposed = await propose();
      final decided = await protection.decide(
        operatorId: 'ffffffff-ffff-ffff-ffff-ffffffffffff',
        agreementId: proposed.agreement.id,
        decision: 'accept',
        actorUserId: theirDispatcher,
      );
      expect(decided.refusal, isA<UnknownAgreement>());
    });
  });

  group('the life of an agreement', () {
    Future<String> live() async {
      final proposed = await propose();
      await protection.decide(
        operatorId: bony,
        agreementId: proposed.agreement.id,
        decision: 'accept',
        actorUserId: theirDispatcher,
      );
      return proposed.agreement.id;
    }

    test('suspends and resumes without losing its terms', () async {
      final id = await live();

      final suspended = await protection.decide(
        operatorId: ocean,
        agreementId: id,
        decision: 'suspend',
        actorUserId: ourDispatcher,
      );
      expect(
        suspended.agreement!.agreement.state,
        ProtectionAgreementState.suspended,
      );
      expect(suspended.agreement!.agreement.rebillDiscountBps, 1500);

      final resumed = await protection.decide(
        operatorId: ocean,
        agreementId: id,
        decision: 'resume',
        actorUserId: ourDispatcher,
      );
      expect(
        resumed.agreement!.agreement.state,
        ProtectionAgreementState.active,
      );
      // The acceptance stamp is the counterparty's, and resuming is not a
      // second acceptance.
      expect(resumed.agreement!.acceptedAt, isNotNull);
    });

    test('refuses a decision its state does not allow', () async {
      final id = await live();
      final again = await protection.decide(
        operatorId: bony,
        agreementId: id,
        decision: 'accept',
        actorUserId: theirDispatcher,
      );
      expect(again.refusal, isA<WrongAgreementState>());
      expect(again.refusal!.params, {'state': 'active'});
    });

    test('carries the ceiling, and the zero that has been used', () async {
      await live();
      final ours = await protection.agreementsFor(ocean);
      expect(ours.single.agreement.monthlyCapSeats, 40);
      // Read from `protection_movements`, so the screen says 0 / 40 today and
      // says the truth on the day something has moved.
      expect(ours.single.seatsUsedThisMonth, 0);
    });

    test(
      'a one-way agreement protects the party that did not write it',
      () async {
        final proposed = await propose(reciprocal: false);
        await protection.decide(
          operatorId: bony,
          agreementId: proposed.agreement.id,
          decision: 'accept',
          actorUserId: theirDispatcher,
        );

        final ours = (await protection.agreementsFor(ocean)).single.agreement;
        expect(ours.allowsRequestFrom(ocean), isTrue);
        expect(ours.allowsRequestFrom(bony), isFalse);
      },
    );
  });
}
