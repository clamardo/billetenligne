import 'package:bel_admin/src/application/admin_workspace.dart';
import 'package:bel_admin/src/presentation/app.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';
import 'scripted_admin.dart';

void main() {
  late TranslationCatalog catalog;

  setUpAll(() async => catalog = await loadTestCatalog());

  Future<AdminWorkspace> pump(
    WidgetTester tester,
    ScriptedAdmin gateway, {
    String language = 'fr',
    void Function(String code)? onLanguage,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final workspace = AdminWorkspace(gateway: gateway);
    await tester.pumpWidget(
      AdminApp(
        catalog: catalog,
        workspace: workspace,
        language: language,
        onLanguage: onLanguage,
      ),
    );
    await tester.pumpAndSettle();
    return workspace;
  }

  Future<void> statePolicy(WidgetTester tester, AdminWorkspace w) async {
    w.setReason('dossier complet, RCCM vérifié');
    await tester.pumpAndSettle();
  }

  group('the language this back office is read in', () {
    // It passed the literal `'fr'` in three places and asked nobody.

    testWidgets('choosing one repaints the back office and is handed out', (
      tester,
    ) async {
      final chosen = <String>[];
      await pump(
        tester,
        ScriptedAdmin(capabilities: const ['platform.operator.review']),
        onLanguage: chosen.add,
      );

      await tester.tap(find.byTooltip('Langue'));
      await tester.pumpAndSettle();

      // Written in its own name, from the catalog's manifest.
      expect(find.text('English'), findsOneWidget);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(find.text('Applications'), findsWidgets);
      expect(chosen, ['en']);
    });

    testWidgets('it opens in the language it was handed', (tester) async {
      // What the composition root passes after resolving the browser's own
      // preference list against the catalog.
      await pump(
        tester,
        ScriptedAdmin(capabilities: const ['platform.operator.review']),
        language: 'en',
      );
      expect(find.text('Operators'), findsWidgets);
    });
  });

  group('the rail is built from capabilities', () {
    testWidgets('a reviewer who may reconcile sees all three', (tester) async {
      await pump(
        tester,
        ScriptedAdmin(
          capabilities: const [
            'platform.operator.review',
            'platform.payment.reconcile',
          ],
        ),
      );

      for (final label in const ['Dossiers', 'Compagnies', 'Paiements']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('a viewer sees no queue at all', (tester) async {
      await pump(
        tester,
        ScriptedAdmin(capabilities: const ['booking.read', 'finance.read']),
      );

      // Not greyed, not 403ing on tap. Absent (ADR-0011).
      expect(find.text('Dossiers'), findsNothing);
      expect(find.text('Paiements'), findsNothing);
    });

    testWidgets('a failure to load identity is a retry, not a blank app', (
      tester,
    ) async {
      await pump(
        tester,
        ScriptedAdmin(capabilities: const [])
          ..identityFailure = const NetworkUnreachable(),
      );

      expect(find.textContaining('Réessayer'), findsWidgets);
    });
  });

  group("the applicant's own answers", () {
    /// The operator page is a long ListView and off-screen children are not
    /// built, so a card below the fold is genuinely absent from the tree.
    Future<void> scrollToEnd(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -400));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('the checklist is the applicant\'s, not a second one', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator()];
      gateway.file = AdminOperatorDetailDto(
        operator: adminOperator(),
        submittedAt: DateTime.utc(2026, 8, 2),
        application: const ApplicationFacts(
          legalName: 'Océan du Nord SARL',
          ownerName: 'Angèle Mbemba',
          ownerPhone: '+242060192286',
          settlementKind: 'momo',
          settlementAccountName: 'Océan du Nord',
        ),
      );

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();
      await scrollToEnd(tester);

      expect(find.text('Angèle Mbemba'), findsOneWidget);
      // Named in the reader's language, from the same list the applicant saw.
      expect(find.textContaining('Il manque'), findsWidgets);
      expect(
        find.textContaining('Numéro RCCM (registre du commerce)'),
        findsWidgets,
      );
      expect(find.textContaining('rccmNumber'), findsNothing);
    });

    testWidgets('a settlement account in somebody else\'s name is flagged', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator()];
      gateway.file = AdminOperatorDetailDto(
        operator: adminOperator(),
        application: const ApplicationFacts(
          legalName: 'Océan du Nord SARL',
          settlementAccountName: 'Trans Bony Voyages',
        ),
      );

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();
      await scrollToEnd(tester);

      // The one automatic comparison this screen makes, because a reviewer
      // reading two strings forty times a week will eventually not.
      expect(find.textContaining('ne correspond pas'), findsOneWidget);
    });

    testWidgets('an operator onboarded before self-signup shows no card', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator()];
      gateway.file = AdminOperatorDetailDto(operator: adminOperator());

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();
      await scrollToEnd(tester);

      // Null rather than empty, so "applied and left it blank" and "arrived
      // by SQL in the first week" do not read the same.
      expect(find.text("Le dossier d'inscription"), findsNothing);
    });
  });

  group('nothing happens without a reason', () {
    testWidgets('every decision is disabled until one is typed', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator()];
      gateway.file = AdminOperatorDetailDto(operator: adminOperator());

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();

      final approve = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.text('Approuver'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(approve.onTap, isNull);

      // And the reason it is disabled is on screen, rather than a grey
      // rectangle somebody has to guess at.
      expect(find.textContaining('Indiquez un motif'), findsWidgets);

      await statePolicy(tester, workspace);
      final enabled = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.text('Approuver'),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(enabled.onTap, isNotNull);
    });

    testWidgets('the workspace refuses a write with a blank reason', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator()];

      final workspace = await pump(tester, gateway);
      await workspace.decide(operatorId: 'op-1', decision: 'approve');

      // The server's 400 is the control; this is what stops somebody losing a
      // typed paragraph to it.
      expect(gateway.calls.where((c) => c.startsWith('decide:')), isEmpty);
    });
  });

  group('the lifecycle table decides which buttons exist', () {
    testWidgets('an application under review offers approve, not reinstate', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const [
          'platform.operator.review',
          'platform.operator.suspend',
        ],
      )..roster = [adminOperator()];
      gateway.file = AdminOperatorDetailDto(operator: adminOperator());

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();

      expect(find.text('Approuver'), findsOneWidget);
      expect(find.text('Refuser'), findsOneWidget);
      expect(find.text('Réactiver'), findsNothing);
      expect(find.text('Mettre en service'), findsNothing);
    });

    testWidgets('a suspended operator offers only reinstate', (tester) async {
      final suspended = adminOperator(status: 'suspended');
      final gateway = ScriptedAdmin(
        capabilities: const [
          'platform.operator.review',
          'platform.operator.suspend',
        ],
      )..roster = [suspended];
      gateway.file = AdminOperatorDetailDto(operator: suspended);

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();

      expect(find.text('Réactiver'), findsOneWidget);
      expect(find.text('Approuver'), findsNothing);
      expect(find.text('Suspendre'), findsNothing);
    });

    testWidgets('a rejected file offers nothing, and says so', (tester) async {
      final rejected = adminOperator(status: 'rejected');
      final gateway = ScriptedAdmin(
        capabilities: const [
          'platform.operator.review',
          'platform.operator.suspend',
        ],
      )..roster = [rejected];
      gateway.file = AdminOperatorDetailDto(operator: rejected);

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();

      expect(find.textContaining('Impossible depuis'), findsOneWidget);
    });
  });

  testWidgets('a decision carries the reason and the detail', (tester) async {
    final gateway = ScriptedAdmin(
      capabilities: const ['platform.operator.review'],
    )..roster = [adminOperator()];
    gateway.file = AdminOperatorDetailDto(operator: adminOperator());

    final workspace = await pump(tester, gateway);
    await workspace.open('op-1');
    await tester.pumpAndSettle();
    await statePolicy(tester, workspace);

    await tester.tap(find.text('Approuver'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).last,
      'assurance à jour au 12/09',
    );
    await tester.tap(find.text('Valider la décision'));
    await tester.pumpAndSettle();

    expect(
      gateway.calls,
      contains(
        'decide:op-1:approve:dossier complet, RCCM vérifié:'
        'assurance à jour au 12/09',
      ),
    );
  });

  testWidgets('the commission is basis points, whatever the field says', (
    tester,
  ) async {
    final gateway = ScriptedAdmin(
      capabilities: const [
        'platform.operator.review',
        'platform.operator.offboard',
      ],
    )..roster = [adminOperator()];
    gateway.file = AdminOperatorDetailDto(operator: adminOperator());

    final workspace = await pump(tester, gateway);
    await workspace.open('op-1');
    await tester.pumpAndSettle();
    await statePolicy(tester, workspace);

    // 7.5% is 750 bps. A rate that reaches the wire as 7.5 is a hundredfold
    // error in what we take from a fare.
    await tester.enterText(find.byType(TextField).last, '7.5');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer la commission'));
    await tester.pumpAndSettle();

    expect(
      gateway.calls,
      contains('commission:op-1:750:dossier complet, RCCM vérifié'),
    );
  });

  group('the queue arrives pre-sorted', () {
    testWidgets('an unassessed file wears no band at all', (tester) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator()];

      await pump(tester, gateway);

      // Absent is not `low`. A queue that drew them the same would let a file
      // nobody has looked at read as cleared.
      for (final label in const ['Automatique', 'À instruire', 'À examiner']) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('a sorted file names its reasons, not a count', (tester) async {
      final gateway =
          ScriptedAdmin(capabilities: const ['platform.operator.review'])
            ..roster = [
              adminOperator(
                riskBand: 'elevated',
                riskReasons: const ['duplicate_operator', 'fleet_too_large'],
              ),
            ];

      await pump(tester, gateway);

      expect(find.text('À examiner'), findsOneWidget);
      // "2 signaux" would tell a reviewer to open the file to find out what
      // they are, which is the click this whole sorting exists to save.
      expect(
        find.textContaining("doublon d'une compagnie existante"),
        findsOneWidget,
      );
      expect(
        find.textContaining('flotte au-dessus du seuil automatique'),
        findsOneWidget,
      );
    });

    testWidgets('an automatic approval has nothing to explain', (tester) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [adminOperator(status: 'active', riskBand: 'low')];

      await pump(tester, gateway);

      expect(find.text('Automatique'), findsOneWidget);
    });
  });

  group('the compliance calendar', () {
    ComplianceDto standing({
      required String stage,
      String name = 'Trans Bony Voyages',
      String? blockedDoc,
      int days = 12,
    }) => ComplianceDto(
      operatorId: 'op-7',
      operatorName: name,
      stage: stage,
      blockedDoc: blockedDoc,
      salesBlockedAt: blockedDoc == null ? null : DateTime.utc(2026, 4, 2),
      documents: [
        ComplianceDocDto(
          docType: 'fleet_insurance',
          expiresAt: DateTime.utc(2026, 4, 1),
          stage: stage,
          daysLeft: days,
        ),
      ],
    );

    testWidgets('a row names the company, the paper and the days', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..calendar = [standing(stage: 'urgent', days: 5)];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.compliance);
      await tester.pumpAndSettle();

      expect(find.text('Trans Bony Voyages'), findsOneWidget);
      expect(find.text("attestation d'assurance"), findsOneWidget);
      expect(find.text('dans 5 j'), findsOneWidget);
      expect(find.text('Dernière semaine'), findsOneWidget);
    });

    testWidgets('what has already lapsed says so, not "in −3 days"', (
      tester,
    ) async {
      final gateway =
          ScriptedAdmin(capabilities: const ['platform.operator.review'])
            ..calendar = [
              standing(
                stage: 'blocked',
                blockedDoc: 'fleet_insurance',
                days: -3,
              ),
            ];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.compliance);
      await tester.pumpAndSettle();

      // Signed on the wire, and read on both sides of zero: "expired 3 days
      // ago" is a phone call and "in 3 days" is a diary note.
      expect(find.text('expirée depuis 3 j'), findsOneWidget);
      expect(
        find.textContaining("Vente arrêtée : attestation d'assurance"),
        findsOneWidget,
      );
    });

    testWidgets('widening the window is a fresh read', (tester) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      );

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.compliance);
      await tester.pumpAndSettle();

      await tester.tap(find.text('365 jours'));
      await tester.pumpAndSettle();

      // The window is the server's filter, not the screen's: a calendar that
      // filtered a list it had already fetched would show sixty days of rows
      // whatever the chip said.
      expect(gateway.calls, contains('compliance:365:'));
    });

    testWidgets('an empty calendar is an answer, not a blank', (tester) async {
      final workspace = await pump(
        tester,
        ScriptedAdmin(capabilities: const ['platform.operator.review']),
      );
      workspace.openSection(AdminSection.compliance);
      await tester.pumpAndSettle();

      expect(find.text('Rien à relancer'), findsOneWidget);
    });
  });

  group('the payout queue', () {
    testWidgets('the whole statement is in the row, cash included', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(capabilities: const ['finance.read'])
        ..runs = [payoutRun()];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payouts);
      await tester.pumpAndSettle();

      // The person approving is agreeing to a number and should be able to
      // check it here rather than trust it: both halves of the difference,
      // and the cash line that is never paid out but is always asked about.
      expect(find.textContaining('412 billet'), findsOneWidget);
      expect(find.textContaining('188 billet'), findsOneWidget);
      expect(find.text('Espèces en caisse (déduites)'), findsOneWidget);
    });

    testWidgets('an analyst may read the queue and not move it', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(capabilities: const ['finance.read'])
        ..runs = [payoutRun()];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payouts);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      // "Has Océan du Nord been paid?" is answerable without holding the
      // authority to pay them.
      final button = tester.widget<KButton>(
        find.widgetWithText(KButton, 'Approuver ce relevé'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('approving says the money has not gone yet', (tester) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['finance.read', 'payout.approve'],
      )..runs = [payoutRun()];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payouts);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      await tester.tap(find.text('Approuver ce relevé'));
      await tester.pumpAndSettle();

      expect(
        gateway.calls,
        contains('payout:pay-1:approve:dossier complet, RCCM vérifié:'),
      );
      // Approval is not payment, and a notice that did not say so is how a
      // reviewer tells an operator the money is on its way a day early.
      expect(find.textContaining("pas encore parti"), findsOneWidget);
    });

    testWidgets('the money cannot be sent without a reference', (tester) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['finance.read', 'payout.approve'],
      )..runs = [payoutRun(state: 'approved')];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payouts);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      // A transfer nobody can find in a bank statement afterwards is a
      // transfer that gets sent twice.
      final blocked = tester.widget<KButton>(
        find.widgetWithText(KButton, "Envoyer l'argent"),
      );
      expect(blocked.onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, 'MOMO-4471-88');
      await tester.pumpAndSettle();
      await tester.tap(find.text("Envoyer l'argent"));
      await tester.pumpAndSettle();

      expect(
        gateway.calls,
        contains(
          'payout:pay-1:release:dossier complet, RCCM vérifié:MOMO-4471-88',
        ),
      );
      // The notice repeats the reference, which is what a reviewer copies
      // into whatever ledger their finance team actually keeps.
      expect(
        find.textContaining('envoyés. Référence MOMO-4471-88'),
        findsOneWidget,
      );
    });

    testWidgets('an operator who owes us is not offered a transfer', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['finance.read', 'payout.approve'],
      )..runs = [payoutRun(net: -54000)];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payouts);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      // Money the wrong way round is an invoice and a conversation. Not a
      // greyed-out button, and certainly not a payout with a minus sign.
      expect(find.text('Approuver ce relevé'), findsNothing);
      expect(find.textContaining('nous doit'), findsOneWidget);
    });
  });

  group('the reconciliation queue', () {
    testWidgets('reask needs no evidence — it asks the rail, not a human', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.payment.reconcile'],
      )..queue = [unresolvedPayment()];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payments);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      await tester.tap(find.text("Redemander à l'opérateur"));
      await tester.pumpAndSettle();

      expect(
        gateway.calls,
        contains('resolve:pi-1:reask:dossier complet, RCCM vérifié::'),
      );
    });

    testWidgets('declaring a payment captured demands what was seen', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.payment.reconcile'],
      )..queue = [unresolvedPayment()];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payments);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      await tester.tap(find.text('Déclarer payé'));
      await tester.pumpAndSettle();

      // "Somebody marked it paid" is not an answer six weeks later, so the
      // confirm button does not exist until there is a sentence.
      final blocked = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirmer'),
      );
      expect(blocked.onPressed, isNull);

      await tester.enterText(
        find.byType(TextField).last,
        'relevé marchand MTN ligne 4412',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer'));
      await tester.pumpAndSettle();

      expect(
        gateway.calls,
        contains(
          'resolve:pi-1:captured:dossier complet, RCCM vérifié:'
          'relevé marchand MTN ligne 4412:',
        ),
      );
    });

    testWidgets('a failure carries a code from the rails\' own taxonomy', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.payment.reconcile'],
      )..queue = [unresolvedPayment()];

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.payments);
      await tester.pumpAndSettle();
      await statePolicy(tester, workspace);

      await tester.tap(find.text('Déclarer échoué'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'MTN confirme aucun débit',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirmer'));
      await tester.pumpAndSettle();

      expect(
        gateway.calls,
        contains(
          'resolve:pi-1:failed:dossier complet, RCCM vérifié:'
          'MTN confirme aucun débit:payment.timeout_no_response',
        ),
      );
    });
  });

  group('the funnel', () {
    FunnelDayDto day(
      String d, {
      int held = 0,
      int reserved = 0,
      int paid = 0,
      int lapsed = 0,
      int failed = 0,
    }) => FunnelDayDto(
      day: d,
      held: held,
      reserved: reserved,
      paid: paid,
      holdsLapsed: lapsed,
      paymentsFailed: failed,
    );

    testWidgets('the screen says what it does not measure', (tester) async {
      final gateway = ScriptedAdmin(capabilities: const ['finance.read'])
        ..funnelResult = FunnelDto(
          days: [day('2026-08-10', held: 40, reserved: 20, paid: 15)],
        );

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.funnel);
      await tester.pumpAndSettle();

      // The most important sentence on the screen: nothing here counts the
      // people who searched and left, because nothing records a search.
      expect(
        find.textContaining('commence à la place bloquée'),
        findsOneWidget,
      );
      expect(find.text('40'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
    });

    testWidgets('a ten point fall is on the screen, not in a mailbox', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(capabilities: const ['finance.read'])
        ..funnelResult = FunnelDto(
          days: [
            day('2026-08-10', held: 10, reserved: 8, paid: 5),
            day('2026-08-09', held: 10, reserved: 10, paid: 9),
          ],
        );

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.funnel);
      await tester.pumpAndSettle();

      expect(find.textContaining('chuté de 40 points'), findsOneWidget);
    });

    testWidgets('a quiet day is drawn as quiet, not as a collapse', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(capabilities: const ['finance.read'])
        ..funnelResult = FunnelDto(days: [day('2026-08-10')]);

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.funnel);
      await tester.pumpAndSettle();

      expect(find.text('Rien ce jour-là'), findsOneWidget);
      expect(find.text('0 %'), findsNothing);
    });

    testWidgets('the window is a choice, and it is asked of the server', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(capabilities: const ['finance.read'])
        ..funnelResult = const FunnelDto(days: []);

      final workspace = await pump(tester, gateway);
      workspace.openSection(AdminSection.funnel);
      await tester.pumpAndSettle();

      await tester.tap(find.text('30 jours'));
      await tester.pumpAndSettle();

      // Re-asked rather than sliced client-side: a fortnight of rows cannot
      // answer a question about the month before it.
      expect(gateway.calls, contains('funnel:30:'));
    });

    testWidgets('a reviewer who cannot read finance never sees the tab', (
      tester,
    ) async {
      final gateway = ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      );

      await pump(tester, gateway);
      await tester.pumpAndSettle();

      expect(find.text('Parcours'), findsNothing);
    });
  });

  testWidgets('the queue asks the server for exactly the pending statuses', (
    tester,
  ) async {
    final gateway = ScriptedAdmin(
      capabilities: const ['platform.operator.review'],
    )..roster = [adminOperator()];

    await pump(tester, gateway);

    expect(
      gateway.calls.first,
      'operators:${AdminOperatorDto.pendingStatuses.length}:',
    );
    expect(find.text('Océan du Nord SARL'), findsOneWidget);
    // The negotiated rate, on the row, because it is what somebody scanning a
    // roster is usually looking for.
    expect(find.textContaining('5%'), findsWidgets);
  });
}
