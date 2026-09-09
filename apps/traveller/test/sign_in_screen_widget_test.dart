import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_design/bel_design.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_localization/bel_localization.dart';
import 'package:bel_traveller/src/application/ports/identity_gateway.dart';
import 'package:bel_traveller/src/application/sign_in_flow.dart';
import 'package:bel_traveller/src/presentation/l10n.dart';
import 'package:bel_traveller/src/presentation/screens/sign_in_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_fixture.dart';

/// A gateway that answers the code however the test wants it answered.
final class _ScriptedIdentity implements IdentityGateway {
  ApiFailure? submitFailure;
  final List<String> submitted = [];
  int resends = 0;

  @override
  AccountDto? account;

  @override
  bool get isSignedIn => account != null;

  @override
  Future<bool> restore() async => false;

  @override
  Future<List<String>> signInChannels() async => const ['email'];

  @override
  Future<SignInChallengeDto> requestCode(
    String email, {
    SignInChannel channel = SignInChannel.email,
  }) async {
    resends++;
    return SignInChallengeDto(
      challengeId: 'ch-$resends',
      channel: channel,
      sentTo: 'a***e@example.cg',
      expiresAt: DateTime.utc(2026, 8, 9, 6, 5),
      resendAfter: const Duration(seconds: 60),
      attemptsRemaining: 5,
    );
  }

  @override
  Future<AccountDto> submitCode({
    required String challengeId,
    required String code,
  }) async {
    submitted.add(code);
    if (submitFailure != null) throw submitFailure!;
    return account = const AccountDto(id: 'u-1', language: 'fr');
  }

  @override
  Future<void> signOut() async => account = null;
}

final class _FixedClock implements Clock {
  const _FixedClock();
  @override
  DateTime now() => DateTime.utc(2026, 8, 9, 6);
}

void main() {
  late TranslationCatalog catalog;
  setUpAll(() async => catalog = await loadTestCatalog());

  late _ScriptedIdentity gateway;
  late SignInFlow flow;

  setUp(() {
    gateway = _ScriptedIdentity();
    flow = SignInFlow(gateway: gateway, clock: const _FixedClock());
  });

  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(
      Localized(
        catalog: catalog,
        initialLanguage: 'fr',
        child: MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: SignInScreen(
            flow: flow,
            onSignedIn: (_) {},
            onCancel: () {},
            now: () => DateTime.utc(2026, 8, 9, 6),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String t(String key) => catalog.mergedStrings('fr')[key]!;

  // The code was right, our API consumed it, and the credential exchange
  // afterwards failed. The screen used to say "Connectez-vous pour continuer"
  // over a submit button that could only ever be refused again.
  group('sign-in accepted the code and still did not finish', () {
    setUp(() {
      gateway.submitFailure = const SignInNotCompleted(
        FirebaseRefused(400, 'INVALID_CUSTOM_TOKEN'),
      );
    });

    testWidgets('says what happened instead of asking them to sign in', (
      tester,
    ) async {
      await host(tester);
      await flow.requestCode('aline@example.cg');
      await tester.pumpAndSettle();

      await flow.submitCode('424242');
      await tester.pumpAndSettle();

      expect(find.text(t('errors.auth.not_completed')), findsOneWidget);
      expect(find.text(t('errors.auth.unauthorized')), findsNothing);
    });

    testWidgets('withdraws the action that can no longer work', (tester) async {
      await host(tester);
      await flow.requestCode('aline@example.cg');
      await tester.pumpAndSettle();
      expect(find.text(t('auth.code.submit')), findsOneWidget);

      await flow.submitCode('424242');
      await tester.pumpAndSettle();

      // No button offering to answer a challenge the server has already
      // closed, and no digits sitting in the field looking submittable.
      expect(find.text(t('auth.code.submit')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        isEmpty,
      );
    });

    testWidgets('offers a new code straight away, with no countdown', (
      tester,
    ) async {
      await host(tester);
      await flow.requestCode('aline@example.cg');
      await tester.pumpAndSettle();

      await flow.submitCode('424242');
      await tester.pumpAndSettle();

      // Not "Renvoyer dans 60 s". The wait was earned by asking for a code
      // too often; this traveller asked once and we lost it.
      final resend = find.text(t('auth.code.resend'));
      expect(resend, findsOneWidget);

      await tester.tap(resend);
      await tester.pumpAndSettle();
      expect(gateway.resends, 2);
    });
  });
}
