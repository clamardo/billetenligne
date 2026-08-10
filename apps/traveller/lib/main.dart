import 'dart:io';

import 'package:bel_client/bel_client.dart';
import 'package:flutter/material.dart';

import 'src/application/booking_flow.dart';
import 'src/application/payment_flow.dart';
import 'src/application/ports/identity_gateway.dart';
import 'src/application/ports/travel_gateway.dart';
import 'src/application/sign_in_flow.dart';
import 'src/application/tickets_flow.dart';
import 'src/infrastructure/api_identity_gateway.dart';
import 'src/infrastructure/api_travel_gateway.dart';
import 'src/infrastructure/demo_identity_gateway.dart';
import 'src/infrastructure/demo_travel_gateway.dart';
import 'src/presentation/app.dart';
import 'src/presentation/l10n.dart';

/// Composition root.
///
/// The only file allowed to know both a port and its adapter. Point it at a
/// running API with:
///
///   flutter run --dart-define=BEL_API_URL=http://10.0.2.2:8080
///
/// `10.0.2.2` is the host machine as seen from the Android emulator, which is
/// the loop this app is actually developed in.
///
/// With no URL it runs on the demo gateways: a working funnel on a fresh
/// clone, so the screens are reviewable by somebody who is not set up to run
/// Postgres.
///
/// Firebase is addressed through its REST API rather than the `firebase_auth`
/// plugin (ADR-0024), so there is no `google-services.json` here and no native
/// platform configuration: point `BEL_FIREBASE_EMULATOR` at the emulator and
/// the whole sign-in works against a `demo-` project with no credentials.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final catalog = await CatalogAssets.load();
  final language = _deviceLanguage();
  const apiUrl = String.fromEnvironment('BEL_API_URL');

  final TravelGateway gateway;
  final IdentityGateway identity;

  if (apiUrl.isEmpty) {
    gateway = DemoTravelGateway();
    identity = DemoIdentityGateway();
  } else {
    final session = BelSession(
      firebase: FirebaseIdentityClient(config: _firebaseConfig()),
      // In memory for now. The refresh token belongs in the Keychain and the
      // Android Keystore (ADR-0013), which is a platform-channel dependency
      // this app does not carry yet — so today a session lasts until the app
      // is killed. Named here rather than hidden behind a default, because
      // "you have to sign in again every launch" is a thing a reviewer should
      // see rather than discover.
      store: MemorySessionStore(),
    );

    final client = BelApiClient(
      baseUrl: Uri.parse(apiUrl),
      // Asked per request, not captured once: tokens expire mid-session and
      // BelSession refreshes them behind this call.
      token: session.token,
      language: language,
    );

    gateway = ApiTravelGateway(client);
    identity = ApiIdentityGateway(client: client, session: session);
  }

  // A session from a previous launch, if there is one to restore. Awaited
  // before the first frame so the funnel does not briefly believe a returning
  // traveller is a stranger.
  await identity.restore();

  runApp(
    TravellerApp(
      catalog: catalog,
      flow: BookingFlow(
        gateway: gateway,
        isSignedIn: () => identity.isSignedIn,
      ),
      signIn: SignInFlow(gateway: identity),
      payment: PaymentFlow(gateway: gateway),
      tickets: TicketsFlow(gateway: gateway),
      language: language,
    ),
  );
}

/// Which Firebase, and how to reach it.
///
/// `BEL_FIREBASE_EMULATOR` is the local loop — a `demo-` project on the host
/// machine that needs no credentials and cannot reach Google (ADR-0020).
/// `10.0.2.2` is the host as seen from the Android emulator, which is where
/// this app is actually developed.
///
/// The API key is not a secret: Firebase publishes it in every web app, and it
/// identifies a project rather than authorising anything. Treating it as one
/// is what leads to it being kept out of the repository and then hardcoded in
/// a hurry.
FirebaseClientConfig _firebaseConfig() {
  const emulator = String.fromEnvironment('BEL_FIREBASE_EMULATOR');
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

/// The handset's language if we speak it, French otherwise.
///
/// French is the source language and the fallback (ADR-0008): a phone set to
/// Lingala or Portuguese gets French, which every traveller in this market
/// reads, rather than English.
String _deviceLanguage() {
  final locale = Platform.localeName;
  return locale.startsWith('en') ? 'en' : 'fr';
}
