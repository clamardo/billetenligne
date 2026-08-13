import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/departures/{id}/seatmap`
///
/// The layout and the live availability in one response, because the client
/// needs both to draw anything and two round trips on 2G is a visibly slower
/// screen.
///
/// Deliberately **not** cached. Everything else on the browse path tolerates a
/// stale minute; this is the screen where somebody is about to tap a specific
/// seat, and showing them a seat that was taken sixty seconds ago produces the
/// one failure this product cannot afford to make routine.
///
/// `?from=DOL&to=PNR` asks about a **piece** of the road (ADR-0025): which
/// seats are free between those two towns, and what the operator charges for
/// them. The client sends the same pair it searched with, so a position in a
/// road it does not own never has to cross the wire. Naming one end and not
/// the other is a client bug and is refused rather than quietly widened to
/// the whole journey — which would be a seat map for a journey nobody asked
/// to buy.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();
  final params = context.request.uri.queryParameters;
  final from = params['from']?.trim().toUpperCase();
  final to = params['to']?.trim().toUpperCase();

  if ((from == null) != (to == null) || (from != null && from == to)) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        params: {'field': from == null ? 'from' : 'to'},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final map = await services.catalogue.seatMap(id, fromCity: from, toCity: to);

  if (map == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: map.toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}
