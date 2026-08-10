import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// Far enough out that these tests do not start failing on a Tuesday.
final _expiry = DateTime.utc(2031, 6, 30);

/// The day the expiry-aware assertions are judged against.
final _today = DateTime.utc(2030, 1, 1);

/// A complete application, which every test below breaks in exactly one way.
ApplicationFacts complete() => ApplicationFacts(
  legalName: 'Ocean du Nord SARL',
  tradingName: 'Ocean du Nord',
  rccmNumber: 'CG-BZV-01-2016-B12-00042',
  taxId: 'M2016110000042',
  legalForm: 'sarl',
  registeredAddress: '12 avenue de la Paix, Brazzaville',
  yearFounded: 2016,
  ownerName: 'Angèle Mbemba',
  ownerIdType: 'passport',
  ownerIdNumber: '20AB12345',
  ownerPhone: '+242060192286',
  ownerEmail: 'angele@oceandunord.cg',
  transportLicenceNumber: 'TR-2024-0871',
  transportLicenceExpires: _expiry,
  insurerName: 'NSIA Congo',
  fleetInsuranceExpires: _expiry,
  routesServed: 'Brazzaville - Pointe-Noire, Brazzaville - Dolisie',
  fleetSize: 14,
  stationCount: 3,
  dailyDepartures: 6,
  settlementKind: 'momo',
  settlementAccountName: 'Ocean du Nord',
  settlementAccountRef: '+242060192286',
  agreementAccepted: true,
);

void main() {
  group('what the wizard still needs', () {
    test('a complete application is submittable and lists nothing missing', () {
      expect(complete().isSubmittable(asOf: _today), isTrue);
      expect(complete().missing(asOf: _today), isEmpty);
      expect(
        complete().stepsComplete(asOf: _today),
        ApplicationStep.values.length,
      );
    });

    test(
      'an empty application names every required field, in wizard order',
      () {
        const empty = ApplicationFacts();

        expect(empty.isSubmittable(), isFalse);
        expect(empty.stepsComplete(), 0);
        // Entreprise before dirigeant before licences: the checklist reads in
        // the order the applicant will meet the fields.
        expect(empty.missing().first, 'legalName');
        expect(empty.missing(), contains('fleetInsuranceExpires'));
        expect(empty.missing().last, 'agreement');
      },
    );

    test(
      'an insurance certificate that has already lapsed is not an answer',
      () {
        final facts = complete().copyWith(
          fleetInsuranceExpires: DateTime.utc(2029, 12, 31),
        );

        // Present, and worse than absent: a date in the past reads as answered
        // on a checklist.
        expect(facts.missingIn(ApplicationStep.licences), isEmpty);
        expect(facts.missingIn(ApplicationStep.licences, asOf: _today), [
          'fleetInsuranceExpires',
        ]);
        expect(facts.isSubmittable(asOf: _today), isFalse);
      },
    );

    test('a step reports only its own gaps', () {
      const facts = ApplicationFacts(legalName: 'Sotrapo');

      expect(
        facts.missingIn(ApplicationStep.entreprise),
        isNot(contains('ownerName')),
      );
      expect(facts.missingIn(ApplicationStep.dirigeant), contains('ownerName'));
    });

    test('a fleet of zero coaches is not a fleet', () {
      expect(
        complete()
            .copyWith(fleetSize: 0)
            .missingIn(ApplicationStep.exploitation),
        contains('fleetSize'),
      );
    });

    test('an unknown settlement kind is refused', () {
      expect(
        complete()
            .copyWith(settlementKind: 'briefcase')
            .missingIn(ApplicationStep.encaissement),
        contains('settlementKind'),
      );
    });

    test('whitespace is not an answer', () {
      expect(
        complete()
            .copyWith(legalName: '   ')
            .missingIn(ApplicationStep.entreprise),
        contains('legalName'),
      );
    });
  });

  group('the two numbers a registry writes by hand', () {
    test('a real RCCM is accepted however it was punctuated', () {
      for (final n in const [
        'CG-BZV-01-2016-B12-00042',
        'CG/BZV/01/2016/B12/00042',
        'CG BZV 01 2016 B12 00042',
      ]) {
        expect(ApplicationFacts.isValidRccm(n), isTrue, reason: n);
      }
    });

    test('a word with no digits in it is a typo, not a number', () {
      expect(ApplicationFacts.isValidRccm('ABCDEFGH'), isFalse);
      expect(ApplicationFacts.isValidTaxId('SANSNUMERO'), isFalse);
    });

    test('nothing at all is refused without throwing', () {
      expect(ApplicationFacts.isValidRccm(null), isFalse);
      expect(ApplicationFacts.isValidTaxId(''), isFalse);
    });
  });

  group('the settlement account name check', () {
    test('the company form is not a mismatch', () {
      final facts = complete().copyWith(
        legalName: 'Ocean du Nord SARL',
        settlementAccountName: 'OCEAN DU NORD',
      );

      expect(facts.settlementNameMatchesLegalName, isTrue);
    });

    test('somebody else entirely is a mismatch', () {
      expect(
        complete()
            .copyWith(settlementAccountName: 'Trans Bony Voyages')
            .settlementNameMatchesLegalName,
        isFalse,
      );
    });

    test('an empty account name never silently matches', () {
      expect(
        complete()
            .copyWith(settlementAccountName: '  ')
            .settlementNameMatchesLegalName,
        isFalse,
      );
    });
  });

  group('the operator code', () {
    test('is recognisable and suffixed', () {
      expect(operatorCodeFrom('Ocean du Nord SARL', 'k4m'), 'OCEAND-K4M');
    });

    test('survives a name with nothing usable in it', () {
      expect(operatorCodeFrom('!!!', 'ab'), 'OP-ABX');
    });
  });
}
