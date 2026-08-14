import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/web/landing_page.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /` — one address, two readers.
///
/// This route answered a JSON object to everybody until now, which was right
/// for exactly one of the two things that arrive here. A monitoring probe and
/// a curious developer want `{"service":…,"status":"ok"}`. A person who
/// scanned the QR on the side of a coach, read the address off a poster, or
/// tapped *voir les départs* on an operator's storefront wants to be told what
/// this is and where to get the app — and until this file existed, three
/// shipped call-to-action buttons pointed straight at that JSON.
///
/// **The reader is decided by `Accept`, not by a second URL.** A landing page
/// parked on `/home` is an address nobody puts on a poster, and moving the
/// JSON to `/api` would break every probe already pointed here. Browsers send
/// `text/html` in `Accept` and always have; `curl`, `wget` and every uptime
/// checker do not. So the header does the routing, and both readers keep the
/// address they already use.
///
/// `/health` is untouched and remains the endpoint to watch: it is the one
/// that actually knows whether the database answers.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final accept = context.request.headers[HttpHeaders.acceptHeader] ?? '';
  if (!accept.contains('text/html')) {
    return Response.json(
      statusCode: HttpStatus.ok,
      body: const {'service': 'billetenligne', 'status': 'ok'},
    );
  }

  final services = context.read<Services>();
  final query = context.request.uri.queryParameters;
  final language = (query['lang'] ?? 'fr').startsWith('en') ? 'en' : 'fr';

  return Response(
    body: LandingPage.render(
      catalog: Services.translations,
      language: language,
      // The storefront's route links carry the journey somebody already chose.
      // Repeating it is the difference between a page that answers and a page
      // that starts the conversation over.
      from: query['from'],
      to: query['to'],
      playStoreUrl: services.stores.playStoreUrl,
      appStoreUrl: services.stores.appStoreUrl,
      consoleUrl: services.stores.consoleUrl,
    ),
    headers: {
      HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
      // Long enough that a poster campaign is not a load test, short enough
      // that the day a store listing appears the page says so within the hour.
      HttpHeaders.cacheControlHeader: 'public, max-age=300',
      'X-Frame-Options': 'DENY',
    },
  );
}
