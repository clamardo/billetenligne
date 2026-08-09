import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/fleet/vehicles` — the coaches.
/// `POST /console/v1/fleet/vehicles` — add one, or change one.
///
/// A vehicle is a registration plus a pointer at a layout template. That
/// pointer is the whole reuse story: fourteen identical coaches are one
/// template and fourteen rows here, and an operator draws the seat map once.
///
/// Status is on this route too, and it is the interesting part. Moving a coach
/// to `maintenance` returns **the future departures it was carrying**, because
/// taking a vehicle off the road without saying which departures it was
/// running is how bookings get dropped without anybody noticing until the
/// passengers are at the station (`06-fleet-and-routes.md` §2).
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final vehicles = await console.vehicles(scope.operatorId);
      return Response.json(
        body: {'items': [for (final v in vehicles) _json(v)]},
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.fleetManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;

      // A status change and a create are the same verb on the same resource,
      // told apart by which fields arrived. Two routes would mean two places
      // that have to agree about who may touch a vehicle.
      final status = body['status'];
      final id = body['id'];
      if (status is String && id is String) {
        if (!_knownStatus(status)) return _badRequest(trace, 'status');

        final affected = await console.setVehicleStatus(
          operatorId: scope.operatorId,
          vehicleId: id,
          status: status,
        );
        return Response.json(
          body: {
            'id': id,
            'status': status,
            // Never silently: these departures now have no coach, and the
            // operator has to reassign one or declare a disruption.
            'affectedDepartureIds': affected,
          },
          headers: {BelHeaders.traceId: trace},
        );
      }

      final registration = body['registration'];
      final layoutId = body['layoutId'];
      if (registration is! String || registration.trim().isEmpty) {
        return _badRequest(trace, 'registration');
      }
      if (layoutId is! String) return _badRequest(trace, 'layoutId');

      final saved = await console.saveVehicle(
        operatorId: scope.operatorId,
        registration: registration.trim().toUpperCase(),
        layoutId: layoutId,
        id: id as String?,
        nickname: body['nickname'] as String?,
        model: body['model'] as String?,
        amenities: [
          for (final a in (body['amenities'] as List? ?? const [])) '$a',
        ],
      );

      // Null means the layout is not this operator's. Reported as a bad
      // layout id rather than a 403, because saying "that template belongs to
      // somebody else" confirms it exists.
      if (saved == null) return _badRequest(trace, 'layoutId');

      return Response.json(
        statusCode: HttpStatus.created,
        body: _json(saved),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

/// Selling a seat on an uninsured or broken-down coach is a liability we will
/// not carry, so the set is closed and the database agrees
/// (`vehicles_status_known`).
bool _knownStatus(String status) => const {
  'active',
  'maintenance',
  'out_of_service',
  'blocked_compliance',
}.contains(status);

Map<String, Object?> _json(dynamic v) => {
  'id': v.id,
  'registration': v.registration,
  'layoutId': v.layoutId,
  'layoutName': v.layoutName,
  'capacity': v.capacity,
  'status': v.status,
  'sellable': v.isSellable,
  if (v.nickname != null) 'nickname': v.nickname,
  if (v.model != null) 'model': v.model,
  'amenities': v.amenities,
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
