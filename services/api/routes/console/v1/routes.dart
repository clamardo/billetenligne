import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/routes` — where this operator runs.
/// `POST /console/v1/routes` — open a route, or change one.
///
/// A route is a pair of cities and a duration. Duration rather than an arrival
/// time, because the arrival is computed per departure — a route that stored
/// arrival times would need editing every time a timetable moved.
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
          'items': [
            for (final r in routes)
              {
                'id': r.id,
                'code': r.code,
                'originCity': r.originCity,
                'destinationCity': r.destinationCity,
                'durationMinutes': r.durationMinutes,
                'active': r.active,
              },
          ],
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

      final saved = await console.saveRoute(
        operatorId: scope.operatorId,
        code: code.trim().toUpperCase(),
        originCity: origin,
        destinationCity: destination,
        durationMinutes: duration,
        id: body['id'] as String?,
        distanceKm: body['distanceKm'] as int?,
      );

      // Null means the endpoints are the same city. The database refuses it
      // too (`routes_distinct_endpoints`); this says which field to fix.
      if (saved == null) return _badRequest(trace, 'destinationCity');

      return Response.json(
        statusCode: HttpStatus.created,
        body: {
          'id': saved.id,
          'code': saved.code,
          'originCity': saved.originCity,
          'destinationCity': saved.destinationCity,
          'durationMinutes': saved.durationMinutes,
          'active': saved.active,
        },
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
