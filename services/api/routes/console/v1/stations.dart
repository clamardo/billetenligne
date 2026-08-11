import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/stations` — the terminals this operator uses.
/// `POST /console/v1/stations` — open one, correct one, or close one.
///
/// A station is a yard, not a city. In Brazzaville the difference between
/// Mikalou and Kinsoundi is forty minutes of taxi at six in the morning, and
/// it is the single fact an agency's telephone line repeats most often.
///
/// Closed rather than deleted, always: a departure sold last month still has
/// to say where its passengers were told to stand, and the list here shows
/// closed terminals so one can be reopened without a database.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      // Reading is `booking.read`: a counter agent selling a ticket has to be
      // able to tell somebody where to stand.
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final stations = await console.stations(scope.operatorId);
      return Response.json(
        body: {
          'items': [for (final s in stations) _json(s).toJson()],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      // Writing is `route.manage`: where a company's coaches leave from is a
      // network decision, and the same authority that opens a road.
      final denied = Require.capability(context, Capability.routeManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final city = body['cityCode'];
      final name = body['name'];

      if (city is! String || city.trim().isEmpty) {
        return _badRequest(trace, 'cityCode');
      }
      if (name is! String || name.trim().isEmpty) {
        return _badRequest(trace, 'name');
      }

      // Coordinates are optional and refused if half-given: a marker with a
      // latitude and no longitude lands in the Gulf of Guinea.
      final lat = _coordinate(body['lat']);
      final lng = _coordinate(body['lng']);
      if ((lat == null) != (lng == null)) return _badRequest(trace, 'lat');
      if (lat != null && (lat < -90 || lat > 90)) {
        return _badRequest(trace, 'lat');
      }
      if (lng != null && (lng < -180 || lng > 180)) {
        return _badRequest(trace, 'lng');
      }

      final saved = await console.saveStation(
        operatorId: scope.operatorId,
        cityCode: city.trim().toUpperCase(),
        name: name.trim(),
        id: body['id'] as String?,
        lat: lat,
        lng: lng,
        boardingNotes: (body['boardingNotes'] as String?)?.trim(),
        active: body['active'] as bool? ?? true,
      );

      if (saved == null) return _badRequest(trace, 'cityCode');

      return Response.json(
        statusCode: HttpStatus.created,
        body: _json(saved).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

StationDto _json(StationSummary s) => StationDto(
  id: s.id,
  cityCode: s.cityCode,
  name: s.name,
  active: s.active,
  lat: s.lat,
  lng: s.lng,
  boardingNotes: s.boardingNotes,
);

double? _coordinate(Object? raw) => switch (raw) {
  final double d => d,
  final int i => i.toDouble(),
  _ => null,
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
