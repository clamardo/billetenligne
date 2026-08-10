import 'dart:async';
import 'dart:convert';

import 'package:bel_backoffice/bel_backoffice.dart';
import 'package:bel_client/bel_client.dart';
import 'package:bel_design/bel_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// A scripted transport keyed by path, so a test says what the *server*
/// answers and the widget is exercised whole — including the client, the DTOs
/// and the branch that decides whether a session was granted.
final class _Server extends http.BaseClient {
  final Map<String, List<(int, String)>> replies = {};
  final List<String> requests = [];
  final List<String> bodies = [];

  void on(String path, int status, String body) =>
      (replies[path] ??= []).add((status, body));

  /// Every custom token this session actually handed to Firebase. Empty is the
  /// assertion that matters most: a withheld session must not become one.
  /// The last body sent to one path. `bodies.last` would answer with the
  /// Firebase exchange that follows a successful sign-in.
  String bodyFor(String path) =>
      bodies[requests.lastIndexOf(path)];

  List<String> get exchangedTokens => [
    for (var i = 0; i < requests.length; i++)
      if (requests[i].endsWith('signInWithCustomToken'))
        (jsonDecode(bodies[i]) as Map<String, Object?>)['token']! as String,
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = '${request.method} ${request.url.path}';
    requests.add(path);
    bodies.add(request is http.Request ? request.body : '');

    final queue = replies[path];
    if (queue == null || queue.isEmpty) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"error":{"code":"not_found"}}')),
        404,
        request: request,
      );
    }

    final (status, body) = queue.length == 1 ? queue.first : queue.removeAt(0);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      request: request,
    );
  }
}

/// The Firebase exchange, answered by the same scripted transport.
///
/// A real `FirebaseIdentityClient` over a fake socket rather than a fake
/// client, because the thing worth asserting is *whether* the widget exchanged
/// a token — and a stub would answer that question by construction.
const _firebaseExchange = 'POST /identitytoolkit.googleapis.com'
    '/v1/accounts:signInWithCustomToken';

/// The catalog is not what is under test. Keys are echoed back, which makes an
/// assertion read as the key the screen asked for.
String _t(String key, [Map<String, Object?> args = const {}]) => key;

void main() {
  late _Server server;
  late BelApiClient client;
  late BelSession session;
  var signedIn = 0;

  setUp(() {
    server = _Server();
    signedIn = 0;
    server.on(
      _firebaseExchange,
      200,
      '{"idToken":"id-token","refreshToken":"refresh-token","expiresIn":"3600"}',
    );
    client = BelApiClient(
      baseUrl: Uri.parse('http://api.test'),
      httpClient: server,
      retry: RetryPolicy.none,
    );
    session = BelSession(
      firebase: FirebaseIdentityClient(
        config: FirebaseClientConfig.emulator(
          projectId: 'demo',
          host: 'firebase.test',
        ),
        httpClient: server,
      ),
      store: MemorySessionStore(),
    );
  });

  const challenge = '''
  {"challengeId":"c-1","channel":"email","sentTo":"s***e@ocean.cg",
   "expiresAt":"2026-08-10T10:00:00Z","resendAfter":60,"attemptsRemaining":5}
  ''';

  const account = '{"id":"u-1","language":"fr","email":"serge@ocean.cg"}';

  Future<void> pumpSignIn(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: KiloTheme.materialTheme(),
        home: BackOfficeSignIn(
          client: client,
          session: session,
          title: 'Console',
          t: _t,
          onSignedIn: () => signedIn++,
        ),
      ),
    );
  }

  /// Types the address and the emailed code, which is every path's first half.
  Future<void> signInWithCode(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, 'serge@ocean.cg');
    await tester.pump();
    await tester.tap(find.text('auth.email.submit'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pumpAndSettle();
  }

  group('signing in', () {
    testWidgets('a traveller-shaped answer opens the app', (tester) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"customToken":"ct-1","account":$account,"isNewAccount":false}',
      );

      await pumpSignIn(tester);
      await signInWithCode(tester);

      expect(signedIn, 1);
      expect(server.exchangedTokens, ['ct-1']);
    });

    // The whole point of the screen. A session was *not* granted, and the app
    // must not open on the strength of a correct emailed code alone.
    testWidgets('a withheld session asks for six more digits', (tester) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"mfaToken":"half.session","account":$account,"isNewAccount":false}',
      );

      await pumpSignIn(tester);
      await signInWithCode(tester);

      expect(signedIn, 0);
      expect(server.exchangedTokens, isEmpty);
      expect(find.text('auth.mfa.intro'), findsOneWidget);
    });

    testWidgets('the authenticator code completes it', (tester) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"mfaToken":"half.session","account":$account,"isNewAccount":false}',
      );
      server.on(
        'POST /public/v1/auth/sessions/mfa',
        200,
        '{"customToken":"ct-2","account":$account,"isNewAccount":false}',
      );

      await pumpSignIn(tester);
      await signInWithCode(tester);
      await tester.enterText(find.byType(TextField).first, '654321');
      await tester.pumpAndSettle();

      expect(signedIn, 1);
      expect(server.exchangedTokens, ['ct-2']);
      // The half-session goes back exactly as it arrived. A client that
      // re-derived it would be a client that could be talked into forging one.
      final sent = server.bodyFor('POST /public/v1/auth/sessions/mfa');
      expect(sent, contains('"mfaToken":"half.session"'));
      expect(sent, contains('"code":"654321"'));
    });

    testWidgets('a wrong authenticator code says how many are left', (
      tester,
    ) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"mfaToken":"half.session","account":$account,"isNewAccount":false}',
      );
      server.on(
        'POST /public/v1/auth/sessions/mfa',
        401,
        '{"error":{"code":"mfa.incorrect","messageKey":"errors.mfa.incorrect",'
            '"params":{"remaining":3}}}',
      );

      await pumpSignIn(tester);
      await signInWithCode(tester);
      await tester.enterText(find.byType(TextField).first, '000000');
      await tester.pumpAndSettle();

      expect(signedIn, 0);
      expect(find.text('errors.mfa.incorrect'), findsOneWidget);
    });

    // The phone that fell in the river.
    testWidgets('a recovery code is sent as a recovery code', (tester) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"mfaToken":"half.session","account":$account,"isNewAccount":false}',
      );
      server.on(
        'POST /public/v1/auth/sessions/mfa',
        200,
        '{"customToken":"ct-3","account":$account,"isNewAccount":false}',
      );

      await pumpSignIn(tester);
      await signInWithCode(tester);
      await tester.tap(find.text('auth.mfa.useRecovery'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'ABCDE-12345');
      await tester.pump();
      await tester.tap(find.text('auth.mfa.submit'));
      await tester.pumpAndSettle();

      expect(signedIn, 1);
      final sent = server.bodyFor('POST /public/v1/auth/sessions/mfa');
      expect(sent, contains('"recoveryCode":"ABCDE-12345"'));
      expect(sent, isNot(contains('"code"')));
    });
  });

  group('enrolment', () {
    const enrolment = '''
    {"secretBase32":"JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
     "provisioningUri":"otpauth://totp/BilletEnLigne:serge",
     "recoveryCodes":["AAAAA-11111","BBBBB-22222","CCCCC-33333",
                      "DDDDD-44444","EEEEE-55555","FFFFF-66666",
                      "GGGGG-77777","HHHHH-88888"]}
    ''';

    // Staff with nothing enrolled hold a real session — refusing one would
    // have locked out every existing staff account — and see this and nothing
    // else until they finish.
    testWidgets('a must-enrol session lands on the enrolment screen', (
      tester,
    ) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"customToken":"ct-4","mustEnrolSecondFactor":true,'
            '"account":$account,"isNewAccount":false}',
      );
      server.on(
        'GET /public/v1/auth/second-factor',
        200,
        '{"enrolled":false,"required":true,"recoveryCodesRemaining":0}',
      );
      server.on('POST /public/v1/auth/second-factor', 201, enrolment);

      await pumpSignIn(tester);
      await signInWithCode(tester);

      // Signed in — the session is real — but the app is not open.
      expect(server.exchangedTokens, ['ct-4']);
      expect(signedIn, 0);
      expect(find.text('auth.enrol.why'), findsOneWidget);

      // The key is shown in groups of four, because thirty-two characters in
      // one run is a string somebody mistypes.
      expect(find.text('JBSW Y3DP EHPK 3PXP JBSW Y3DP EHPK 3PXP'), findsOne);

      // And the codes are not shown until the factor is proven.
      expect(find.text('AAAAA-11111'), findsNothing);
    });

    testWidgets('confirming reveals the recovery codes, once', (tester) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"customToken":"ct-5","mustEnrolSecondFactor":true,'
            '"account":$account,"isNewAccount":false}',
      );
      server.on(
        'GET /public/v1/auth/second-factor',
        200,
        '{"enrolled":false,"required":true,"recoveryCodesRemaining":0}',
      );
      server.on('POST /public/v1/auth/second-factor', 201, enrolment);
      server.on('POST /public/v1/auth/second-factor/confirm', 204, '');

      await pumpSignIn(tester);
      await signInWithCode(tester);

      await tester.enterText(find.byType(TextField).first, '111111');
      await tester.pumpAndSettle();

      expect(find.text('AAAAA-11111'), findsOneWidget);
      expect(find.text('HHHHH-88888'), findsOneWidget);

      // Leaving is a deliberate act. These exist in readable form here and
      // nowhere else — the server keeps only their HMACs.
      expect(signedIn, 0);
      await tester.tap(find.text('auth.enrol.recoveryKept'));
      await tester.pumpAndSettle();
      expect(signedIn, 1);
    });

    testWidgets('a wrong code does not reveal them', (tester) async {
      server.on('POST /public/v1/auth/challenges', 200, challenge);
      server.on(
        'POST /public/v1/auth/sessions',
        200,
        '{"customToken":"ct-6","mustEnrolSecondFactor":true,'
            '"account":$account,"isNewAccount":false}',
      );
      server.on(
        'GET /public/v1/auth/second-factor',
        200,
        '{"enrolled":false,"required":true,"recoveryCodesRemaining":0}',
      );
      server.on('POST /public/v1/auth/second-factor', 201, enrolment);
      server.on(
        'POST /public/v1/auth/second-factor/confirm',
        401,
        '{"error":{"code":"mfa.incorrect","messageKey":"errors.mfa.incorrect"}}',
      );

      await pumpSignIn(tester);
      await signInWithCode(tester);
      await tester.enterText(find.byType(TextField).first, '000000');
      await tester.pumpAndSettle();

      expect(find.text('AAAAA-11111'), findsNothing);
      expect(find.text('errors.mfa.incorrect'), findsOneWidget);
    });

    // Opening the manage screen with a live factor must not fire a blind
    // enrolment: the server refuses one with a 409, and the person most
    // likely to open this screen is the one who already has a factor.
    testWidgets('an existing factor is managed, not overwritten', (
      tester,
    ) async {
      server.on(
        'GET /public/v1/auth/second-factor',
        200,
        '{"enrolled":true,"required":true,"recoveryCodesRemaining":3,'
            '"confirmedAt":"2026-08-01T09:00:00Z"}',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: SecondFactorEnrolment(
            client: client,
            t: _t,
            onCancel: () {},
            onFinished: () => signedIn++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('auth.enrol.done'), findsOneWidget);
      expect(find.text('auth.enrol.disable'), findsOneWidget);
      expect(
        server.requests.where((r) => r == 'POST /public/v1/auth/second-factor'),
        isEmpty,
      );
    });

    testWidgets('replacing removes the old factor first', (tester) async {
      server.on(
        'GET /public/v1/auth/second-factor',
        200,
        '{"enrolled":true,"required":true,"recoveryCodesRemaining":3}',
      );
      server.on('DELETE /public/v1/auth/second-factor', 204, '');
      server.on('POST /public/v1/auth/second-factor', 201, enrolment);

      await tester.pumpWidget(
        MaterialApp(
          theme: KiloTheme.materialTheme(),
          home: SecondFactorEnrolment(
            client: client,
            t: _t,
            onCancel: () {},
            onFinished: () => signedIn++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('auth.enrol.disable'));
      await tester.pumpAndSettle();

      expect(server.requests, contains('DELETE /public/v1/auth/second-factor'));
      expect(server.requests.last, 'POST /public/v1/auth/second-factor');
      expect(find.text('auth.enrol.why'), findsOneWidget);
    });
  });
}
