import 'dart:io';

import 'package:bel_client/bel_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/application/booking_flow.dart';
import 'src/application/ports/travel_gateway.dart';
import 'src/infrastructure/api_travel_gateway.dart';
import 'src/infrastructure/demo_travel_gateway.dart';
import 'src/presentation/app.dart';
import 'src/presentation/l10n.dart';
import 'src/presentation/screens/search_screen.dart';

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
/// With no URL it runs on the demo gateway: a working funnel on a fresh clone,
/// so the screens are reviewable by somebody who is not set up to run
/// Postgres.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final catalog = await CatalogAssets.load();
  const apiUrl = String.fromEnvironment('BEL_API_URL');

  final TravelGateway gateway = apiUrl.isEmpty
      ? DemoTravelGateway()
      : ApiTravelGateway(
          BelApiClient(
            baseUrl: Uri.parse(apiUrl),
            // Until Firebase Auth is wired, the fake token the API's own
            // in-memory mode accepts. Debug builds only — a release build
            // that ships a working token is a release build that gives
            // everybody the same account.
            token: kDebugMode ? () => 'fake:traveller' : null,
            language: _deviceLanguage(),
          ),
        );

  runApp(
    TravellerApp(
      catalog: catalog,
      flow: BookingFlow(gateway: gateway),
      language: _deviceLanguage(),
      // Hardcoded for now: the cities endpoint is Phase 1's next slice, and
      // Congo's intercity network is genuinely this small. Wrong to leave
      // permanently, harmless today.
      cities: const [
        CityOption('BZV', 'Brazzaville'),
        CityOption('PNR', 'Pointe-Noire'),
        CityOption('DLS', 'Dolisie'),
        CityOption('NKY', 'Nkayi'),
        CityOption('OWE', 'Owando'),
        CityOption('OYO', 'Oyo'),
      ],
    ),
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
