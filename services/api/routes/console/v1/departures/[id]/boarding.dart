import 'dart:convert';
import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/departures/{id}/boarding` — the departure a scanner pins.
///
/// One request in the yard, and then the door works with the radio switched
/// off (ADR-0022): every verdict after this is a signature check against the
/// keys below, a lookup in the ticket list and the device's own redemption
/// log. That is the roadside guarantee, and it is why this is a *download*
/// rather than a per-scan call.
///
/// Behind `boarding.scan`, which the `conductor` role holds and holds alone —
/// the narrowest role in the table (ADR-0011). This response carries the
/// rotating secrets that make a screenshot detectably stale, so a capability
/// that leaked it to a vendor's login would be a capability that let a
/// counter mint freshness codes.
///
/// It deliberately carries **no phone numbers**. The dispatcher's manifest
/// has them because somebody in an office rings a passenger who has not shown
/// up; a conductor's handset is the most easily lost device this company
/// owns, and what is on it should be what the door needs and nothing else.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.boardingScan);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final manifest = await services.console.boardingManifest(
    operatorId: scope.operatorId,
    departureId: id,
  );

  // Not this operator's departure, or not a departure at all. One answer for
  // both: telling a stranger which would confirm the id exists.
  if (manifest == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final keys = await services.tickets.verificationKeys();

  return Response.json(
    body: {
      'departureId': manifest.departureId,
      'operatorCode': manifest.operatorCode,
      'routeCode': manifest.routeCode,
      'departsAt': Wire.instant(manifest.departsAt),
      'capacity': manifest.capacity,
      'tickets': [
        for (final t in manifest.tickets)
          {
            'bookingRef': t.bookingRef,
            'seatLabel': t.seatLabel,
            'passengerName': t.passengerName,
            'secret': base64.encode(t.rotatingSecret),
            if (t.boardsAt != null) 'boardsAt': t.boardsAt,
            if (t.alightsAt != null) 'alightsAt': t.alightsAt,
          },
      ],
      'voided': manifest.voided,
      'keys': {
        for (final e in keys.entries) '${e.key}': base64.encode(e.value),
      },
      // The road, in the same request as the manifest and for the same
      // reason: the tap it exists for happens where there is no signal.
      'waypoints': [
        for (final w in manifest.waypoints)
          {
            'stopId': w.stopId,
            'name': w.name,
            'offsetMinutes': w.offsetMinutes,
            if (w.passedAt != null) 'passedAt': Wire.instant(w.passedAt!),
          },
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      // Secrets and names. A shared cache holding one is a shared cache
      // leaking it, and the device is the only place this belongs.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
