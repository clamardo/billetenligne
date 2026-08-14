import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

final now = DateTime.utc(2026, 3, 1);
final farOff = DateTime.utc(2027, 6, 1);

/// A small company that has filled in everything: the shape the automatic
/// bar was drawn around.
ApplicationFacts small({
  int fleet = 3,
  int departures = 4,
  DateTime? licence,
  DateTime? insurance,
  String? accountName,
}) => ApplicationFacts(
  legalName: 'Sotrapo SARL',
  tradingName: 'Sotrapo',
  rccmNumber: 'CG-DLS-01-2019-B12-00108',
  taxId: 'M2019110000108',
  legalForm: 'sarl',
  registeredAddress: '4 rue de la Gare, Dolisie',
  yearFounded: 2019,
  ownerName: 'Serge Loubaki',
  ownerIdType: 'passport',
  ownerIdNumber: '19CD98765',
  ownerPhone: '+242060192286',
  ownerEmail: 'serge@sotrapo.cg',
  transportLicenceNumber: 'TR-2025-0114',
  transportLicenceExpires: licence ?? farOff,
  insurerName: 'NSIA Congo',
  fleetInsuranceExpires: insurance ?? farOff,
  routesServed: 'Dolisie - Pointe-Noire',
  fleetSize: fleet,
  stationCount: 1,
  dailyDepartures: departures,
  settlementKind: 'momo',
  settlementAccountName: accountName ?? 'Sotrapo',
  settlementAccountRef: '+242060192286',
  agreementAccepted: true,
);

OnboardingRisk assess(
  ApplicationFacts facts, {
  ScreeningOutcome screening = ScreeningOutcome.clear,
  bool duplicate = false,
  bool priorOffboarding = false,
}) => OnboardingRisk.of(
  facts,
  screening: screening,
  duplicate: duplicate,
  priorOffboarding: priorOffboarding,
  now: now,
);

void main() {
  group('the automatic bar', () {
    test('a small, complete, screened application clears it', () {
      final risk = assess(small());

      expect(risk.band, RiskBand.low);
      expect(risk.reasons, isEmpty);
      expect(risk.autoApprovable, isTrue);
    });

    test('no screening is not a clear screening', () {
      // The state of the world today: no vendor is wired, so this is what the
      // adapter actually returns — which is what keeps the whole path off by
      // data rather than by dead code.
      final risk = assess(small(), screening: ScreeningOutcome.notRun);

      expect(risk.band, RiskBand.standard);
      expect(risk.reasons, [RiskReason.screeningNotRun]);
      expect(risk.autoApprovable, isFalse);
    });

    test('a larger company is reviewed, and told which number did it', () {
      final risk = assess(small(fleet: 20));

      expect(risk.band, RiskBand.standard);
      expect(risk.reasons, [RiskReason.fleetTooLarge]);
    });

    test('many departures count even on a small fleet', () {
      expect(assess(small(departures: 40)).reasons, [
        RiskReason.departuresTooMany,
      ]);
    });

    test('a half-filled application is not a risk judgement', () {
      final risk = assess(const ApplicationFacts());

      expect(risk.band, RiskBand.standard);
      expect(risk.reasons, contains(RiskReason.incomplete));
    });
  });

  group('paperwork that is valid but not for long', () {
    test('a licence with two months left is reviewed, not approved', () {
      // Valid today, so `isSubmittable` is happy. Approving here would mean
      // enforcing against them in week nine, which is a worse first quarter
      // than a review.
      final risk = assess(small(licence: DateTime.utc(2026, 4, 25)));

      expect(risk.reasons, [RiskReason.licenceRunway]);
      expect(risk.band, RiskBand.standard);
    });

    test('insurance is judged the same way, and separately', () {
      expect(assess(small(insurance: DateTime.utc(2026, 5, 1))).reasons, [
        RiskReason.insuranceRunway,
      ]);
    });

    test('a year of runway is runway', () {
      expect(assess(small()).reasons, isEmpty);
    });
  });

  group('what a person must see', () {
    test('a screening hit is elevated whatever the fleet size', () {
      final risk = assess(small(fleet: 1), screening: ScreeningOutcome.hit);

      expect(risk.band, RiskBand.elevated);
      expect(risk.autoApprovable, isFalse);
      expect(risk.reasons, contains(RiskReason.screeningHit));
    });

    test('a company we already know is elevated', () {
      expect(assess(small(), duplicate: true).band, RiskBand.elevated);
    });

    test('somebody we offboarded before is elevated', () {
      final risk = assess(small(), priorOffboarding: true);

      expect(risk.band, RiskBand.elevated);
      expect(risk.reasons, contains(RiskReason.priorOffboarding));
    });

    test('an elevated application still lists the ordinary reasons too', () {
      // A reviewer opening this needs the whole picture, not only the
      // headline: the fleet size is part of what they are deciding about.
      final risk = assess(small(fleet: 30), duplicate: true);

      expect(risk.band, RiskBand.elevated);
      expect(
        risk.reasons,
        containsAll([RiskReason.duplicateOperator, RiskReason.fleetTooLarge]),
      );
    });
  });

  test('reasons are sorted, so two runs produce the same row', () {
    final risk = assess(
      small(fleet: 30, accountName: 'Boutique Mabiala'),
      screening: ScreeningOutcome.notRun,
    );

    expect(risk.reasons, [...risk.reasons]..sort());
    expect(risk.reasons, hasLength(3));
  });

  test('the bar is a parameter, not a constant', () {
    final facts = small(fleet: 12);

    expect(assess(facts).band, RiskBand.standard);
    expect(
      OnboardingRisk.of(
        facts,
        screening: ScreeningOutcome.clear,
        now: now,
        limits: const RiskLimits(fleetSize: 20),
      ).band,
      RiskBand.low,
    );
  });
}
