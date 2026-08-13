import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:bel_client/bel_client.dart';
import 'package:bel_secure_store/bel_secure_store.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'src/application/booking_flow.dart';
import 'src/application/payment_flow.dart';
import 'src/application/ports/identity_gateway.dart';
import 'src/application/ports/ticket_vault.dart';
import 'src/application/ports/travel_gateway.dart';
import 'src/application/sign_in_flow.dart';
import 'src/application/tickets_flow.dart';
import 'src/infrastructure/api_identity_gateway.dart';
import 'src/infrastructure/api_travel_gateway.dart';
import 'src/infrastructure/demo_identity_gateway.dart';
import 'src/infrastructure/demo_travel_gateway.dart';
import 'src/infrastructure/sqlite_ticket_vault.dart';
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
  final apiUrl = _reachable(const String.fromEnvironment('BEL_API_URL'));

  final TravelGateway gateway;
  final IdentityGateway identity;

  if (apiUrl.isEmpty) {
    gateway = DemoTravelGateway();
    identity = DemoIdentityGateway();
  } else {
    final session = BelSession(
      firebase: FirebaseIdentityClient(config: _firebaseConfig()),
      // The Keychain on iOS, the Android Keystore on Android (ADR-0013).
      // A refresh token is a ninety-day credential and these handsets are
      // shared, resold and rooted; shared preferences would put it in a file
      // any other app on one can read. Every failure inside it is "not signed
      // in" rather than a crash, because the Keystore genuinely loses keys.
      store: const SecureSessionStore(),
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

  // Where a ticket lives between launches. A failure to open it is not a
  // failure to start: the app falls back to the null vault and behaves
  // exactly as it did before this existed, which is the right trade for a
  // cache — the tickets are still one request away.
  TicketVault vault = const NoTicketVault();
  if (apiUrl.isNotEmpty) {
    try {
      vault = await SqliteTicketVault.open();
    } on Object {
      vault = const NoTicketVault();
    }
  }

  // A session from a previous launch, if there is one to restore. Awaited
  // before the first frame so the funnel does not briefly believe a returning
  // traveller is a stranger.
  await identity.restore();

  // The app may have been launched *by* a ticket link (ADR-0026). Android's
  // App Links hand the URL in as the initial route — no plugin channel, and it
  // is here before the first frame, which is the difference between opening on
  // the ticket and opening on the search screen and then jumping.
  //
  // Remembered rather than acted on: a walk-in opening their first link is
  // usually not signed in yet, and the claim needs an account to claim for.
  final tickets = TicketsFlow(gateway: gateway, vault: vault);
  final token = _ticketLinkToken(PlatformDispatcher.instance.defaultRouteName);
  if (token != null) tickets.rememberLink(token);

  runApp(
    TravellerApp(
      catalog: catalog,
      flow: BookingFlow(
        gateway: gateway,
        isSignedIn: () => identity.isSignedIn,
      ),
      signIn: SignInFlow(gateway: identity),
      payment: PaymentFlow(
        gateway: gateway,
        // Where the card processor sends the browser once the bank is done.
        // A deep link back into this app, and empty until one is registered —
        // an empty value means "no return leg", which the API turns into a
        // checkout that simply ends on the processor's own page. The traveller
        // still gets their ticket either way: the outcome is settled by
        // polling, never by whether a browser came back (ADR-0005).
        returnUrl: const String.fromEnvironment('BEL_CARD_RETURN_URL').isEmpty
            ? null
            : const String.fromEnvironment('BEL_CARD_RETURN_URL'),
      ),
      tickets: tickets,
      openTicketsOnLaunch: token != null,
      currentUserId: () => identity.account?.id,
      // Only the card rail's hosted checkout uses this. `externalApplication`
      // rather than an in-app web view on purpose: a bank's 3-D Secure step
      // often bounces through the card issuer's own app, and a web view that
      // cannot be left is where those payments die.
      openUrl: (url) => unawaited(
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ),
      language: language,
    ),
  );
}

/// The token in `/b/{token}`, or null for any other launch.
///
/// Parsed rather than pattern-matched on a prefix: `defaultRouteName` is `/`
/// on an ordinary launch, and a route the app does not recognise must open the
/// app normally rather than send somebody to a ticket that does not exist.
String? _ticketLinkToken(String route) {
  final uri = Uri.tryParse(route);
  if (uri == null) return null;
  final parts = uri.pathSegments;
  if (parts.length != 2 || parts.first != 'b' || parts[1].isEmpty) return null;
  return parts[1];
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
    return FirebaseClientConfig.emulator(
      projectId: projectId,
      host: _reachable(emulator),
    );
  }

  return const FirebaseClientConfig(
    apiKey: String.fromEnvironment('BEL_FIREBASE_API_KEY'),
    projectId: projectId,
  );
}

/// `localhost`, as seen from wherever this app is actually running.
///
/// On the Android emulator `localhost` is the *emulator*, and the machine that
/// started it is `10.0.2.2`. Nothing listens on the emulator's own loopback,
/// so a request there does not fail — it hangs until the socket times out,
/// which presents as a spinner that never stops. That is a genuinely hard bug
/// to read, and it cost this project an evening.
///
/// Rewriting it here rather than in the launch configuration means there is
/// **one** way to point this app at a local server, and it is right whether
/// the app is on the emulator, on a desktop build or in a test. A real device
/// is untouched: it needs the machine's address on the network, which is
/// neither of these names and so falls straight through.
///
/// Deployed builds never see this. `BEL_API_URL` is then a public hostname,
/// and a URL that is not loopback is returned exactly as it was given.
String _reachable(String value) {
  if (!Platform.isAndroid || value.isEmpty) return value;
  return value
      .replaceAll('localhost', '10.0.2.2')
      .replaceAll('127.0.0.1', '10.0.2.2');
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
