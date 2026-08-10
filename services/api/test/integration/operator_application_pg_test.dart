@Tags(['integration'])
library;

import 'package:bel_api/src/application/ports/operator_applications.dart';
import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_operator_applications.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_platform_console.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Self-signup, against the boundary that actually enforces it.
///
/// The claims a fake cannot make, and every one of them is a claim about
/// migration 0015 rather than about Dart:
///
///   * an applicant writes into `operators` **as `bel_public`**, and the only
///     status they can write is `application_draft`;
///   * the four columns they may edit are a column-level grant, so approving
///     themselves or cutting their own commission is refused by the database;
///   * submission moves the status through a SECURITY DEFINER function whose
///     body is one transition, and it writes the audit row the applicant has
///     no grant to write;
///   * **activation makes them staff** — which is the difference between an
///     approval and a business.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresOperatorApplications applications;
  late PostgresPlatformConsole platform;
  late String reviewer;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    applications = PostgresOperatorApplications(db);
    platform = PostgresPlatformConsole(db);
    reviewer = await fixture.platformStaff('operations', suffix: '-onboard');
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  String suffix() =>
      '${++seq}${DateTime.now().microsecondsSinceEpoch % 100000}';

  /// A signed-in member of the public who has never sold a ticket.
  Future<String> applicantAccount() => fixture.traveller('9${suffix()}');

  ApplicationFacts filled({DateTime? insuranceExpires}) => ApplicationFacts(
    legalName: 'Sotrapo SARL',
    tradingName: 'Sotrapo',
    rccmNumber: 'CG-BZV-01-2019-B12-00123',
    taxId: 'M2019110000123',
    legalForm: 'sarl',
    registeredAddress: '4 rue Fulbert Youlou, Dolisie',
    yearFounded: 2019,
    ownerName: 'Prosper Loubaki',
    ownerIdType: 'passport',
    ownerIdNumber: '19CD98765',
    ownerPhone: '+242060192286',
    ownerEmail: 'prosper@sotrapo.cg',
    transportLicenceNumber: 'TR-2025-0044',
    transportLicenceExpires: DateTime.utc(2032, 3, 31),
    insurerName: 'NSIA Congo',
    fleetInsuranceExpires: insuranceExpires ?? DateTime.utc(2032, 1, 31),
    routesServed: 'Dolisie - Pointe-Noire',
    fleetSize: 3,
    stationCount: 2,
    dailyDepartures: 4,
    settlementKind: 'momo',
    settlementAccountName: 'Sotrapo',
    settlementAccountRef: '+242060192286',
    agreementAccepted: true,
  );

  group('the wizard', () {
    test('an account with no application has none', () async {
      expect(await applications.mine(userId: await applicantAccount()), isNull);
    });

    test(
      'starting one creates a draft operator and nothing sellable',
      () async {
        final user = await applicantAccount();

        final started = await applications.start(
          userId: user,
          legalName: 'Sotrapo SARL',
          marketCode: 'CG',
        );

        final application = started.valueOrNull!;
        expect(application.status, 'application_draft');
        expect(application.code, startsWith('SOTRAP-'));
        expect(application.facts.legalName, 'Sotrapo SARL');

        // Not on sale, and not by accident: `application_draft` is the only
        // status the public role's INSERT policy permits.
        expect(
          await fixture.operatorStatus(application.operatorId),
          'application_draft',
        );
      },
    );

    test(
      'a second application is refused while the first is in flight',
      () async {
        final user = await applicantAccount();
        await applications.start(
          userId: user,
          legalName: 'Sotrapo SARL',
          marketCode: 'CG',
        );

        final again = await applications.start(
          userId: user,
          legalName: 'Sotrapo Deux',
          marketCode: 'CG',
        );

        expect(again.failureOrNull, ApplicationRefusal.alreadyApplied);
      },
    );

    test(
      'saving replaces the whole record, so a retry cannot half-apply',
      () async {
        final user = await applicantAccount();
        await applications.start(
          userId: user,
          legalName: 'Sotrapo SARL',
          marketCode: 'CG',
        );

        await applications.save(userId: user, facts: filled());
        final saved = await applications.save(userId: user, facts: filled());

        final facts = saved.valueOrNull!.facts;
        expect(facts.rccmNumber, 'CG-BZV-01-2019-B12-00123');
        expect(facts.ownerEmail, 'prosper@sotrapo.cg');
        expect(facts.fleetInsuranceExpires, DateTime.utc(2032, 1, 31));
        expect(facts.agreementAccepted, isTrue);
        expect(facts.isSubmittable(asOf: DateTime.utc(2031, 1, 1)), isTrue);
      },
    );

    test('an application nobody sees is nobody else\'s to edit', () async {
      final mine = await applicantAccount();
      final stranger = await applicantAccount();
      await applications.start(
        userId: mine,
        legalName: 'Sotrapo SARL',
        marketCode: 'CG',
      );

      // The stranger holds a valid session. They simply are not the
      // applicant, and RLS is what makes that a fact rather than a policy.
      expect(await applications.mine(userId: stranger), isNull);
      expect(
        (await applications.save(
          userId: stranger,
          facts: filled(),
        )).failureOrNull,
        ApplicationRefusal.noApplication,
      );
    });
  });

  group('submitting', () {
    test('an incomplete application is refused by the server too', () async {
      final user = await applicantAccount();
      await applications.start(
        userId: user,
        legalName: 'Sotrapo SARL',
        marketCode: 'CG',
      );

      final submitted = await applications.submit(
        userId: user,
        asOf: DateTime.utc(2031),
      );

      expect(submitted.failureOrNull, ApplicationRefusal.incomplete);
    });

    test(
      'an insurance certificate that lapsed in the meantime is refused',
      () async {
        final user = await applicantAccount();
        await applications.start(
          userId: user,
          legalName: 'Sotrapo SARL',
          marketCode: 'CG',
        );
        await applications.save(
          userId: user,
          facts: filled(insuranceExpires: DateTime.utc(2030, 1, 31)),
        );

        final submitted = await applications.submit(
          userId: user,
          asOf: DateTime.utc(2031),
        );

        expect(submitted.failureOrNull, ApplicationRefusal.incomplete);
      },
    );

    test('a complete one reaches the queue, and locks', () async {
      final user = await applicantAccount();
      final started = await applications.start(
        userId: user,
        legalName: 'Sotrapo SARL',
        marketCode: 'CG',
      );
      final operatorId = started.valueOrNull!.operatorId;
      await applications.save(userId: user, facts: filled());

      final submitted = await applications.submit(
        userId: user,
        asOf: DateTime.utc(2031),
      );

      expect(submitted.valueOrNull!.status, 'under_review');
      expect(submitted.valueOrNull!.submittedAt, isNotNull);

      // Locked: the wizard reopens when a reviewer asks for information, and
      // not before.
      expect(
        (await applications.save(userId: user, facts: filled())).failureOrNull,
        ApplicationRefusal.locked,
      );

      // And the row the applicant has no grant to write.
      final detail = await platform.operatorDetail(
        operatorId,
        actorUserId: reviewer,
      );
      expect(detail!.trail.map((e) => e.action), contains('operator.apply'));
      expect(detail.application!.facts.ownerName, 'Prosper Loubaki');
      expect(detail.application!.isSubmitted, isTrue);
    });
  });

  group('what the reviewer does with it', () {
    test('requesting information reopens the wizard', () async {
      final user = await applicantAccount();
      final started = await applications.start(
        userId: user,
        legalName: 'Sotrapo SARL',
        marketCode: 'CG',
      );
      await applications.save(userId: user, facts: filled());
      await applications.submit(userId: user, asOf: DateTime.utc(2031));

      await platform.decide(
        operatorId: started.valueOrNull!.operatorId,
        decision: OperatorDecision.requestInfo,
        actorUserId: reviewer,
        reason: 'The insurance certificate is unreadable',
      );

      final reopened = await applications.mine(userId: user);
      expect(reopened!.status, 'info_requested');
      expect(reopened.isEditable, isTrue);
      expect(
        (await applications.save(userId: user, facts: filled())).isOk,
        isTrue,
      );
    });

    test(
      'activation makes the applicant the operator\'s first owner',
      () async {
        final user = await applicantAccount();
        final started = await applications.start(
          userId: user,
          legalName: 'Sotrapo SARL',
          marketCode: 'CG',
        );
        final operatorId = started.valueOrNull!.operatorId;
        await applications.save(userId: user, facts: filled());
        await applications.submit(userId: user, asOf: DateTime.utc(2031));

        // Nobody is staff of an operator that is still an application.
        expect(await fixture.staffRoles(operatorId, user), isEmpty);

        for (final decision in [
          OperatorDecision.approve,
          OperatorDecision.activate,
        ]) {
          final decided = await platform.decide(
            operatorId: operatorId,
            decision: decision,
            actorUserId: reviewer,
            reason: 'Documents check out',
          );
          expect(decided.isOk, isTrue, reason: decision.name);
        }

        // This is the line that removes the phone call: the person who filled
        // in the form can now sign into the console.
        expect(await fixture.staffRoles(operatorId, user), ['org_owner']);
      },
    );

    test('a rejected applicant may start again', () async {
      final user = await applicantAccount();
      final started = await applications.start(
        userId: user,
        legalName: 'Sotrapo SARL',
        marketCode: 'CG',
      );
      await applications.save(userId: user, facts: filled());
      await applications.submit(userId: user, asOf: DateTime.utc(2031));
      await platform.decide(
        operatorId: started.valueOrNull!.operatorId,
        decision: OperatorDecision.reject,
        actorUserId: reviewer,
        reason: 'RCCM belongs to a different company',
      );

      final again = await applications.start(
        userId: user,
        legalName: 'Sotrapo Transport SARL',
        marketCode: 'CG',
      );

      expect(again.isOk, isTrue);
      expect(again.valueOrNull!.status, 'application_draft');
    });
  });
}
