import 'dart:io';

import 'package:bel_api/src/application/search_departures.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/trips?from=BZV&to=PNR&date=2026-08-15`
///
/// The first screen with anything on it, and open to anyone. Forcing sign-up
/// before a traveller sees a price is the largest avoidable drop-off in this
/// funnel (ADR-0013), so there is no auth check here at all.
///
/// Cached for a minute, and honestly. A seat count is a rendering hint — the
/// hold transaction is what decides — so serving a slightly stale list is a
/// deliberate trade for a screen that appears instantly on 2G. What is *not*
/// traded is correctness at the moment of purchase.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final query = SearchDeparturesQuery.fromQuery(
    context.request.uri.queryParameters,
  );

  final result = await services.searchDepartures(
    query,
    now: services.clock.now(),
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      body: {
        'items': [for (final d in value) d.toJson()],
        // Echoed back so a client rendering a stale response can tell which
        // day it is looking at — a real bug on a slow connection where two
        // searches are in flight and the second answers first.
        'query': query.toQuery(),
      },
      headers: {
        BelHeaders.traceId: trace,
        HttpHeaders.cacheControlHeader: 'public, max-age=60',
      },
    ),
    Err(:final SearchFailure failure) => _error(failure, trace),
  };
}

Response _error(SearchFailure failure, String trace) {
  final error = Problem.fromFailure(failure, traceId: trace);
  return Response.json(
    statusCode: Problem.statusFor(error.code),
    body: error.toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}
