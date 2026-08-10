import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/cities` — where you can go.
///
/// Open to anonymous callers and the first request the app makes, because the
/// search screen cannot render without it.
///
/// **Cached for an hour, and that is deliberate.** This is the one answer in
/// the product that is safe to be slightly out of date: a city added this
/// morning appearing this afternoon costs nobody a booking, while a
/// round trip on every app launch costs every traveller a slice of a prepaid
/// bundle. The seat map, one screen later, is `no-store` for exactly the
/// opposite reason.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final language = context.request.headers[BelHeaders.language] ?? 'fr';

  final cities = await context.read<Services>().cities.servedCities(
    // The server resolves the name. A client that picked between `nameFr` and
    // `nameEn` would one day pick wrong for a language it does not know it
    // has.
    language: language,
  );

  return Response.json(
    body: {
      'items': [for (final city in cities) city.toJson()],
    },
    headers: {
      BelHeaders.traceId: trace,
      // Varies by language, and a shared cache that ignored that would serve
      // a French traveller an English list.
      'Vary': BelHeaders.language,
      HttpHeaders.cacheControlHeader: 'public, max-age=3600',
    },
  );
}
