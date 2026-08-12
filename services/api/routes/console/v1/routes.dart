import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/routes` — where this operator runs.
/// `POST /console/v1/routes` — open a route, or change one.
///
/// A route is a pair of cities, a duration, and the places in between.
/// Duration rather than an arrival time, because the arrival is computed per
/// departure — a route that stored arrival times would need editing every
/// time a timetable moved.
///
/// **Stops replace, they do not merge.** A route form is a whole description
/// of a road, and a POST that merged would leave a stop the operator deleted
/// still standing on the timetable. Omitting `stops` entirely leaves them
/// alone, so a caller that predates this field cannot wipe a road by saving
/// its duration.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final routes = await console.routes(scope.operatorId);
      return Response.json(
        body: {
          'items': [for (final r in routes) _routeJson(r)],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.routeManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final code = body['code'];
      final origin = body['originCity'];
      final destination = body['destinationCity'];
      final duration = body['durationMinutes'];

      if (code is! String || code.trim().isEmpty) {
        return _badRequest(trace, 'code');
      }
      if (origin is! String) return _badRequest(trace, 'originCity');
      if (destination is! String) return _badRequest(trace, 'destinationCity');
      if (duration is! int || duration < 1) {
        return _badRequest(trace, 'durationMinutes');
      }

      // Absent means "leave the road as it is"; present — even empty — means
      // "this is the whole road now", which is how a stop gets removed.
      Itinerary? itinerary;
      if (body.containsKey('stops')) {
        final raw = body['stops'];
        if (raw is! List) return _badRequest(trace, 'stops');

        final List<RouteStopDto> parsed;
        try {
          parsed = [
            for (final entry in raw)
              RouteStopDto.fromJson((entry as Map).cast<String, Object?>()),
          ];
        } on Object {
          return _badRequest(trace, 'stops');
        }

        final built = Itinerary.of(
          [for (final stop in parsed) stop.toDomain()],
          originCity: origin,
          destinationCity: destination,
          durationMinutes: duration,
        );

        // The domain's own reason, not a generic 400. "Dolisie is after the
        // coach arrives" is a sentence the console can write; "stops is
        // invalid" is one somebody has to guess at.
        if (built.failureOrNull case final refusal?) {
          return Response.json(
            statusCode: HttpStatus.badRequest,
            body: ApiError(
              code: refusal.code,
              params: refusal.params,
              traceId: trace,
            ).toJson(),
            headers: {BelHeaders.traceId: trace},
          );
        }
        itinerary = built.valueOrNull;
      }

      final saved = await console.saveRoute(
        operatorId: scope.operatorId,
        code: code.trim().toUpperCase(),
        originCity: origin,
        destinationCity: destination,
        durationMinutes: duration,
        id: body['id'] as String?,
        distanceKm: body['distanceKm'] as int?,
        stops: itinerary,
      );

      // Null means the endpoints are the same city. The database refuses it
      // too (`routes_distinct_endpoints`); this says which field to fix.
      if (saved == null) return _badRequest(trace, 'destinationCity');

      return Response.json(
        statusCode: HttpStatus.created,
        body: _routeJson(saved),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Map<String, Object?> _routeJson(RouteSummary route) => {
  'id': route.id,
  'code': route.code,
  'originCity': route.originCity,
  'destinationCity': route.destinationCity,
  'durationMinutes': route.durationMinutes,
  'active': route.active,
  'stops': [
    for (final stop in route.stops)
      RouteStopDto.fromDomain(
        stop,
        stationName: stop.stationId == null
            ? null
            : route.stopStationNames[stop.stationId],
      ).toJson(),
  ],
};

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
