import 'package:bel_admin/src/application/admin_workspace.dart';
import 'package:bel_admin/src/application/ports/admin_gateway.dart';
import 'package:bel_admin/src/presentation/app.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// A gateway the test drives directly, and which records what it was asked.
///
/// It records the **reason** on every call, because that is the property this
/// surface exists to have: an action with no attributable actor and no stated
/// reason is the thing ADR-0011 forbids, and a test that only checks the
/// screen renders would not notice it going missing.
final class _ScriptedAdmin implements AdminGateway {
  _ScriptedAdmin({required this.capabilities});

  List<String> capabilities;
  ApiFailure? identityFailure;

  List<AdminOperatorDto> roster = const [];
  List<UnresolvedPaymentDto> queue = const [];
  List<PayoutRunDto> runs = const [];
  AdminOperatorDetailDto? file;

  /// `call:argument:…:reason`, in order.
  final calls = <String>[];

  @override
  Future<AdminIdentityDto> identity() async {
    if (identityFailure != null) throw identityFailure!;
    return AdminIdentityDto(
      userId: 'u-1',
      role: 'operations',
      capabilities: capabilities,
      fullName: 'Sarah N.',
    );
  }

  @override
  Future<List<AdminOperatorDto>> operators({
    Set<String> statuses = const {},
    required String reason,
  }) async {
    calls.add('operators:${statuses.length}:$reason');
    return roster;
  }

  @override
  Future<AdminOperatorDetailDto> operatorDetail(
    String id, {
    required String reason,
  }) async {
    calls.add('detail:$id:$reason');
    return file!;
  }

  @override
  Future<AdminOperatorDto> decide({
    required String operatorId,
    required String decision,
    required String reason,
    String? detail,
  }) async {
    calls.add('decide:$operatorId:$decision:$reason:${detail ?? ''}');
    return roster.first;
  }

  @override
  Future<AdminOperatorDto> setCommission({
    required String operatorId,
    required int commissionBps,
    required String reason,
  }) async {
    calls.add('commission:$operatorId:$commissionBps:$reason');
    return roster.first;
  }

  @override
  Future<List<UnresolvedPaymentDto>> unresolvedPayments({
    required String reason,
  }) async {
    calls.add('payments:$reason');
    return queue;
  }

  @override
  Future<List<PayoutRunDto>> payouts({required String reason}) async {
    calls.add('payouts:$reason');
    return runs;
  }

  @override
  Future<PayoutRunDto> preparePayout({
    required String operatorId,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String reason,
  }) async {
    calls.add('prepare:$operatorId:$reason');
    return runs.first;
  }

  @override
  Future<PayoutRunDto> decidePayout({
    required String runId,
    required String decision,
    required String reason,
    String? paymentReference,
  }) async {
    calls.add('payout:$runId:$decision:$reason:${paymentReference ?? ''}');
    return _run(
      state: decision == 'release' ? 'paid' : 'approved',
      reference: paymentReference,
    );
  }

  @override
  Future<UnresolvedPaymentDto> resolvePayment({
    required String intentId,
    required String outcome,
    required String reason,
    String? evidence,
    String? failureCode,
  }) async {
    calls.add(
      'resolve:$intentId:$outcome:$reason:${evidence ?? ''}:'
      '${failureCode ?? ''}',
    );
    return queue.first;
  }
}

PayoutRunDto _run({
  String state = 'draft',
  int net = 3516000,
  String? reference,
}) => PayoutRunDto(
  id: 'pay-1',
  operatorId: 'op-1',
  operatorName: 'Océan du Nord',
  periodStart: DateTime.utc(2026, 8, 1),
  periodEnd: DateTime.utc(2026, 8, 8),
  onlineSalesCount: 412,
  onlineGross: const Money.xaf(3708000),
  cashSalesCount: 188,
  cashGross: const Money.xaf(1692000),
  commission: const Money.xaf(185400),
  serviceFees: const Money.xaf(180000),
  refunds: const Money.xaf(126000),
  payable: const Money.xaf(3708000),
  tills: const Money.xaf(192000),
  net: Money.xaf(net),
  state: state,
  preparedAt: DateTime.utc(2026, 8, 8, 9),
  destination: 'MoMo ****4471',
  reference: reference,
);

AdminOperatorDto _operator({
  String status = 'under_review',
  int commissionBps = 500,
  DateTime? createdAt,
}) => AdminOperatorDto(
  id: 'op-1',
  code: 'ODN',
  legalName: 'Océan du Nord SARL',
  tradingName: 'Océan du Nord',
  status: status,
  marketCode: 'CG',
  createdAt: createdAt ?? DateTime.utc(2026, 8, 1),
  commissionBps: commissionBps,
  rccmNumber: 'CG-BZV-01-2019-B12-00042',
  documentCount: 2,
  expiringDocumentCount: 1,
  vehicleCount: 14,
  routeCount: 3,
  staffCount: 9,
);

UnresolvedPaymentDto _payment() => UnresolvedPaymentDto(
  intentId: 'pi-1',
  state: 'indeterminate',
  railId: 'mtn',
  amount: const Money.xaf(12300),
  payerMsisdn: '+242061234567',
  createdAt: DateTime.utc(2026, 8, 10, 6),
  bookingId: 'bk-1',
  bookingRef: 'BEL-7QK4M2',
  bookingState: 'pending_payment',
  operatorId: 'op-1',
  operatorName: 'Océan du Nord',
  pollAttempts: 4,
  travellerPhone: '+242069876543',
);

void main() {
  late TranslationCatalog catalog;

  setUpAll(() async => catalog = await loadTestCatalog());

  Future<AdminWorkspace> pump(
    WidgetTester tester,
    _ScriptedAdmin gateway,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    final workspace = AdminWorkspace(gateway: gateway);
    await tester.pumpWidget(AdminApp(catalog: catalog, workspace: workspace));
    await tester.pumpAndSettle();
    return workspace;
  }

  Future<void> statePolicy(WidgetTester tester, AdminWorkspace w) async {
    w.setReason('dossier complet, RCCM vérifié');
    await tester.pumpAndSettle();
  }

  group('the rail is built from capabilities', () {
    testWidgets('a reviewer who may reconcile sees all three', (tester) async {
      await pump(
        tester,
        _ScriptedAdmin(
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
        _ScriptedAdmin(capabilities: const ['booking.read', 'finance.read']),
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
        _ScriptedAdmin(capabilities: const [])
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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [_operator()];
      gateway.file = AdminOperatorDetailDto(
        operator: _operator(),
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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [_operator()];
      gateway.file = AdminOperatorDetailDto(
        operator: _operator(),
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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [_operator()];
      gateway.file = AdminOperatorDetailDto(operator: _operator());

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [_operator()];
      gateway.file = AdminOperatorDetailDto(operator: _operator());

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.operator.review'],
      )..roster = [_operator()];

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
      final gateway = _ScriptedAdmin(
        capabilities: const [
          'platform.operator.review',
          'platform.operator.suspend',
        ],
      )..roster = [_operator()];
      gateway.file = AdminOperatorDetailDto(operator: _operator());

      final workspace = await pump(tester, gateway);
      await workspace.open('op-1');
      await tester.pumpAndSettle();

      expect(find.text('Approuver'), findsOneWidget);
      expect(find.text('Refuser'), findsOneWidget);
      expect(find.text('Réactiver'), findsNothing);
      expect(find.text('Mettre en service'), findsNothing);
    });

    testWidgets('a suspended operator offers only reinstate', (tester) async {
      final suspended = _operator(status: 'suspended');
      final gateway = _ScriptedAdmin(
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
      final rejected = _operator(status: 'rejected');
      final gateway = _ScriptedAdmin(
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
    final gateway = _ScriptedAdmin(
      capabilities: const ['platform.operator.review'],
    )..roster = [_operator()];
    gateway.file = AdminOperatorDetailDto(operator: _operator());

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
    final gateway = _ScriptedAdmin(
      capabilities: const [
        'platform.operator.review',
        'platform.operator.offboard',
      ],
    )..roster = [_operator()];
    gateway.file = AdminOperatorDetailDto(operator: _operator());

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

  group('the payout queue', () {
    testWidgets('the whole statement is in the row, cash included', (
      tester,
    ) async {
      final gateway = _ScriptedAdmin(capabilities: const ['finance.read'])
        ..runs = [_run()];

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
      final gateway = _ScriptedAdmin(capabilities: const ['finance.read'])
        ..runs = [_run()];

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['finance.read', 'payout.approve'],
      )..runs = [_run()];

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['finance.read', 'payout.approve'],
      )..runs = [_run(state: 'approved')];

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['finance.read', 'payout.approve'],
      )..runs = [_run(net: -54000)];

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.payment.reconcile'],
      )..queue = [_payment()];

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.payment.reconcile'],
      )..queue = [_payment()];

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
      final gateway = _ScriptedAdmin(
        capabilities: const ['platform.payment.reconcile'],
      )..queue = [_payment()];

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

  testWidgets('the queue asks the server for exactly the pending statuses', (
    tester,
  ) async {
    final gateway = _ScriptedAdmin(
      capabilities: const ['platform.operator.review'],
    )..roster = [_operator()];

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
