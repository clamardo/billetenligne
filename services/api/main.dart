import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:dart_frog/dart_frog.dart';

/// Runs before the socket opens.
///
/// One job: read `config/markets.yaml` and refuse to start if it cannot be
/// read as markets. Composition itself is lazy — `_services` in the root
/// middleware resolves on the first request — which is fine for a database
/// that may be briefly unreachable, and wrong for configuration.
///
/// The difference is what a failure looks like. A malformed rail list that
/// surfaces on the first request gives you an instance that passes its health
/// check, joins the load balancer, and answers every `/public/v1/market` with
/// a 500 — or worse, if the loader were forgiving, with last release's rails
/// under a green deploy. Thrown here, the process dies before it is ever
/// healthy, the rollout stops, and the previous version keeps serving.
Future<void> init(InternetAddress ip, int port) async {
  final catalog = Services.marketCatalog();
  stdout.writeln(
    'market ${catalog.defaultMarket.code} '
    '(${catalog.defaultMarket.currency.code}), '
    '${catalog.defaultMarket.rails.where((r) => r.enabled).length} rails live',
  );
}

Future<HttpServer> run(Handler handler, InternetAddress ip, int port) =>
    serve(handler, ip, port);
