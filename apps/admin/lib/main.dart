import 'dart:ui' show PlatformDispatcher;

import 'package:bel_client/bel_client.dart';
import 'package:flutter/material.dart';

import 'src/application/admin_workspace.dart';
import 'src/infrastructure/api_admin_gateway.dart';
import 'src/presentation/l10n.dart';
import 'src/infrastructure/language_preference.dart';
import 'src/infrastructure/theme_preference.dart';
import 'src/presentation/sign_in.dart';

/// Composition root.
///
///   flutter run -d chrome --dart-define=BEL_API_URL=http://localhost:8080
///
/// No demo mode, and here the reason is sharper than the console's: a fake
/// back office would show fabricated operators being approved and fabricated
/// payments being settled. Every screen in this app exists to record that a
/// real person made a real decision about a real tenant, and a mode that
/// invents all three teaches the opposite of what the surface is for.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final catalog = await CatalogAssets.load();

  // The browser's own preference list, resolved against the catalog, rather
  // than the literal `'fr'` that stood here. `PlatformDispatcher` rather than
  // `dart:io`: this is a web app, and `Platform` does not exist here at all.
  // A stored choice beats the browser, because a preference that lasts until
  // the tab closes is not a preference.
  final language =
      await loadLanguage() ??
      catalog.bestMatch(
        PlatformDispatcher.instance.locales.map((l) => l.toLanguageTag()),
      );
  const apiUrl = String.fromEnvironment(
    'BEL_API_URL',
    defaultValue: 'http://localhost:8080',
  );

  // Declared before the session so the session can call back into it: a
  // browser session has no local state to read, so "am I signed in?" is a
  // request, and "sign me out" is a request too (J11).
  late final BelApiClient client;

  final session = BelSession(
    firebase: FirebaseIdentityClient(config: _firebaseConfig()),
    probe: () => client.me(),
    endServerSession: () => client.endWebSession(),
    // Still memory, and now it holds nothing at all: the session lives in an
    // `HttpOnly` cookie the server sets (J11), so there is no refresh token
    // on this page to keep anywhere. A back-office session now survives a
    // page reload — which it had to, because a reviewer who refreshes
    // mid-application was being asked for a code and an authenticator every
    // time — and it still ends on the server the moment they sign out.
    store: MemorySessionStore(),
  );

  client = BelApiClient(
    baseUrl: Uri.parse(apiUrl),
    token: session.token,
    language: language,
  );

  // The cookie set at the last sign-in, if there is one. `HttpOnly` means
  // this code cannot look, so asking the server is the only way to find out —
  // and a failure here is simply "not signed in", which is the sign-in screen
  // this app already opens on.
  await session.restore();

  runApp(
    AdminRoot(
      mode: await loadThemeMode(),
      catalog: catalog,
      language: language,
      // Three places: the tree has already repainted, the preference store
      // survives a reload, and the account row is what the server writes this
      // reviewer's own e-mails in tomorrow (ADR-0019 rule 3). Best-effort on
      // the last, like `touch`.
      onLanguage: (code) async {
        await saveLanguage(code);
        try {
          await client.setLanguage(code);
        } on Object {
          // Nothing to tell them. The screen already changed.
        }
      },
      session: session,
      client: client,
      buildWorkspace: () => AdminWorkspace(gateway: ApiAdminGateway(client)),
    ),
  );
}

/// Which Firebase, and how to reach it.
///
/// The API key is not a secret — Firebase publishes it in every web app, and
/// it identifies a project rather than authorising anything.
FirebaseClientConfig _firebaseConfig() {
  const emulator = String.fromEnvironment(
    'BEL_FIREBASE_EMULATOR',
    defaultValue: 'localhost:9099',
  );
  const projectId = String.fromEnvironment(
    'BEL_FIREBASE_PROJECT',
    defaultValue: 'demo-billetenligne',
  );

  if (emulator.isNotEmpty) {
    return FirebaseClientConfig.emulator(projectId: projectId, host: emulator);
  }
  return const FirebaseClientConfig(
    apiKey: String.fromEnvironment('BEL_FIREBASE_API_KEY'),
    projectId: projectId,
  );
}
