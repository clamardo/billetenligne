import 'package:bel_client/bel_client.dart';
import 'package:flutter/material.dart';

import 'src/application/console_workspace.dart';
import 'src/infrastructure/api_console_gateway.dart';
import 'src/presentation/l10n.dart';
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
  const apiUrl = String.fromEnvironment(
    'BEL_API_URL',
    defaultValue: 'http://localhost:8080',
  );

  final session = BelSession(
    firebase: FirebaseIdentityClient(config: _firebaseConfig()),
    // In memory, like the traveller app and for the same reason: secure
    // storage is a platform-channel dependency neither app carries yet. On
    // web the honest equivalent would be a same-site cookie set by the
    // server, which is a slice of its own — so today a console session ends
    // when the tab closes, and that is stated rather than discovered.
    store: MemorySessionStore(),
  );

  final client = BelApiClient(
    baseUrl: Uri.parse(apiUrl),
    token: session.token,
    language: 'fr',
  );

  runApp(
    ConsoleRoot(
      catalog: catalog,
      session: session,
      client: client,
      buildWorkspace: () =>
          ConsoleWorkspace(gateway: ApiConsoleGateway(client)),
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
