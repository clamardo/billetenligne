import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/boarding?date=YYYY-MM-DD` — the conductor's own list
/// (ADR-0022).
///
/// **A second list rather than a filter on the dispatcher's.** That one is
/// read under `booking.read`, and a conductor does not have it: `conductor` is
/// `{boarding.scan}` and nothing else, deliberately, because the handset most
/// likely to be left on a seat should be the one that can read the least.
/// Widening `booking.read` to reach this screen would have handed every
/// conductor the whole day's load factors on every coach the company runs.
///
/// So this row carries route, hour, yard and how many people are expected —
/// the four things somebody standing in a yard at half past five needs to pick
/// their coach — and no money, no held seats and no passenger names.
///
/// The list is small and it is the thing standing between a conductor and a
/// working door, so it is **never cached**: pinning the wrong departure is
/// discovered at the coach door, by a queue.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.boardingScan);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();

  final raw = context.request.uri.queryParameters['date'];
  final date = raw == null ? null : DateTime.tryParse(raw);
  if (date == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        params: const {'field': 'date'},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final departures = await context.read<Services>().console.boardingDay(
    operatorId: scope.operatorId,
    localDate: date,
  );

  return Response.json(
    body: {
      'departures': [
        for (final d in departures)
          BoardingDepartureDto(
            id: d.id,
            routeCode: d.routeCode,
            originCity: d.originCity,
            destinationCity: d.destinationCity,
            departsAt: d.departsAt,
            expected: d.expected,
            capacity: d.capacity,
            status: d.status,
            stationName: d.stationName,
          ).toJson(),
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
