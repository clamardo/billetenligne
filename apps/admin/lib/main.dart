import 'package:bel_client/bel_client.dart';
import 'package:flutter/material.dart';

import 'src/application/admin_workspace.dart';
import 'src/infrastructure/api_admin_gateway.dart';
import 'src/presentation/l10n.dart';
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
  const apiUrl = String.fromEnvironment(
    'BEL_API_URL',
    defaultValue: 'http://localhost:8080',
  );

  final session = BelSession(
    firebase: FirebaseIdentityClient(config: _firebaseConfig()),
    // In memory, like the other two surfaces. On web the honest equivalent
    // is a same-site cookie set by the server, which is a slice of its own —
    // so today a back-office session ends when the tab closes. For this
    // surface that is closer to a feature than a gap.
    store: MemorySessionStore(),
  );

  final client = BelApiClient(
    baseUrl: Uri.parse(apiUrl),
    token: session.token,
    language: 'fr',
  );

  runApp(
    AdminRoot(
      catalog: catalog,
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
