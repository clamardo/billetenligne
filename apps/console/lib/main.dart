import 'dart:ui' show PlatformDispatcher;

import 'package:bel_client/bel_client.dart';
import 'package:flutter/material.dart';

import 'src/application/console_workspace.dart';
import 'src/application/onboarding_workspace.dart';
import 'src/infrastructure/api_console_gateway.dart';
import 'src/infrastructure/api_onboarding_gateway.dart';
import 'src/infrastructure/web_file_picker.dart';
import 'src/infrastructure/web_file_saver.dart';
import 'src/presentation/l10n.dart';
import 'src/infrastructure/language_preference.dart';
import 'src/infrastructure/theme_preference.dart';
import 'src/presentation/sign_in.dart';

/// Composition root.
///
///   flutter run -d chrome --dart-define=BEL_API_URL=http://localhost:8080
///
/// Unlike the traveller app there is **no demo mode**. The console configures
/// the world the traveller browses — coaches, routes, timetables — and a fake
/// one would be a second definition of every one of those, kept in sync by
/// hand and wrong the first week nobody remembered to. The API refuses the
/// whole surface with a 503 naming `DATABASE_URL` when there is no database,
/// and this app surfaces that rather than papering over it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final catalog = await CatalogAssets.load();

  // The browser's own preference list, resolved against the catalog — not the
  // literal `'fr'` that stood here, which answered French to an agency in
  // Pointe-Noire running an English Windows install and to every reviewer who
  // opened the console with an English browser. `PlatformDispatcher` rather
  // than `dart:io`: this is a web app, and `Platform` does not exist here at
  // all. A stored choice beats the browser, because a preference that lasts
  // until the tab closes is not a preference.
  final language =
      await loadLanguage() ??
      catalog.bestMatch(
        PlatformDispatcher.instance.locales.map((l) => l.toLanguageTag()),
      );
  const apiUrl = String.fromEnvironment(
    'BEL_API_URL',
    defaultValue: 'http://localhost:8080',
  );

  final session = BelSession(
    firebase: FirebaseIdentityClient(config: _firebaseConfig()),
    // In memory, and deliberately still so now that the handset apps use the
    // Keychain and the Keystore (`bel_secure_store`). **That package has a
    // web implementation and it is not secure storage**: it puts an AES key
    // in `localStorage` next to the value it encrypts, which is obfuscation
    // wearing the word *secure*. On web the honest equivalent is a same-site
    // cookie set by the server, which is a slice of its own — so today a
    // console session ends when the tab closes, and that is stated rather
    // than dressed up.
    store: MemorySessionStore(),
  );

  final client = BelApiClient(
    baseUrl: Uri.parse(apiUrl),
    token: session.token,
    language: language,
  );

  runApp(
    ConsoleRoot(
      mode: await loadThemeMode(),
      catalog: catalog,
      language: language,
      // Three places, and all three matter. The tree repaints (done before
      // this is called); the preference store survives a reload; and the
      // account row is what the server writes a staff member's own e-mails in
      // tomorrow, with no browser open anywhere (ADR-0019 rule 3). Best-effort
      // on the last one, like `touch`: refusing to switch language because the
      // network is down is the opposite of useful.
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
      buildWorkspace: () => ConsoleWorkspace(
        gateway: ApiConsoleGateway(client),
        // The one thing this app does that a widget test cannot. Absent,
        // the vitrine screen omits the upload control rather than showing
        // a button that opens nothing.
        files: const WebFilePicker(),
        downloads: const WebFileSaver(),
      ),
      // Built only if the server says this account belongs to no operator.
      buildOnboarding: () =>
          OnboardingWorkspace(gateway: ApiOnboardingGateway(client)),
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
