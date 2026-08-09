import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/departures/{id}/manifest` — who is on this coach.
///
/// The document a conductor carries and a station manager signs. Two rules
/// shape it:
///
///   * **Only confirmed bookings appear.** A reservation nobody has paid for
///     is not a passenger, and putting one on a manifest is how a conductor
///     ends up arguing at the roadside with somebody holding a phone.
///   * **Boarded is a fact, not a claim.** It comes from `redemptions`, which
///     has one row per ticket ever — the primary key is the double-boarding
///     guard — so the count here is what the scanner actually did.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.bookingRead);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();

  final manifest = await context.read<Services>().console.manifest(
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

  return Response.json(
    body: {
      'departureId': manifest.departureId,
      'routeCode': manifest.routeCode,
      'departsAt': Wire.instant(manifest.departsAt),
      'capacity': manifest.capacity,
      'sold': manifest.sold,
      'boarded': manifest.boarded,
      'passengers': [
        for (final row in manifest.rows)
          {
            'seatLabel': row.seatLabel,
            'passengerName': row.passengerName,
            'bookingRef': row.bookingRef,
            'boarded': row.boarded,
            if (row.passengerPhone != null) 'phone': row.passengerPhone,
            if (row.boardedAt != null) 'boardedAt': Wire.instant(row.boardedAt!),
          },
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      // A passenger list with names and phone numbers. A shared cache holding
      // one is a shared cache leaking it.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
