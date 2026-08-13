import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/departures/{id}/checkpoints` — the road, and what is
/// confirmed on it.
/// `POST /console/v1/departures/{id}/checkpoints` — the conductor confirms
/// the coach is past a place (ADR-0014 §1, tier 2).
///
/// The follower page has drawn a dashed bar since it shipped, and said so:
/// *estimation d'après l'horaire*. This is where an observation finally comes
/// from — the handset already on the coach, already pinned to this departure,
/// already trusted to say who boarded it. One more tap, no GPS permission and
/// no driver-facing app that does not exist.
///
/// **A batch, and idempotent**, exactly like the redemptions upload beside
/// it: the tap happens in a dead zone and the outbox empties an hour later,
/// possibly twice. First tap wins by primary key, so a retry cannot overwrite
/// the time the coach was actually there.
///
/// **The device's clock is the one recorded.** It is the only clock that was
/// at the roadside; ours is kept separately as *when we heard*. A page drawn
/// from our clock would report the coach an hour behind itself.
///
/// Behind `boarding.scan` rather than `departure.manage`: this is a
/// conductor's tap, and the narrowest role that can still do the job is the
/// one whose handset going missing costs the least.
Future<Response> onRequest(RequestContext context, String id) async {
  final denied = Require.capability(context, Capability.boardingScan);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final road = await console.waypoints(
        operatorId: scope.operatorId,
        departureId: id,
      );

      // Not this operator's departure, or not a departure at all. One answer
      // for both: telling a stranger which would confirm the id exists.
      if (road == null) {
        return Response.json(
          statusCode: HttpStatus.notFound,
          body: Problem.notFound(traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response.json(
        body: {
          'waypoints': [
            for (final w in road)
              WaypointDto(
                stopId: w.stopId,
                name: w.name,
                offsetMinutes: w.offsetMinutes,
                passedAt: w.passedAt,
              ).toJson(),
          ],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final List<PassageUploadDto> uploads;
      try {
        final body = await context.request.json() as Map<String, Object?>;
        uploads = [
          for (final row in (body['passages'] as List? ?? const []))
            PassageUploadDto.fromJson(row as Map<String, Object?>),
        ];
      } on WireFormatException catch (e) {
        return _badRequest(trace, e.field);
      } on FormatException {
        return _badRequest(trace, 'body');
      } on TypeError {
        return _badRequest(trace, 'passages');
      }

      final result = await console.confirmPassage(
        operatorId: scope.operatorId,
        departureId: id,
        reportedByUserId: context.read<Principal>().userId,
        passages: [
          for (final u in uploads)
            PassageReport(
              stopId: u.stopId,
              passedAt: u.passedAt,
              deviceId: u.deviceId,
            ),
        ],
      );

      // The same two lists as a boarding upload, and the device treats them
      // the same way: both come out of the outbox. A stop id this road has
      // never had will not start being on it, and a queue that retries a
      // permanent failure forever is a handset flat by eleven.
      return Response.json(
        body: BoardingUploadResultDto(
          recorded: result.recorded,
          unknown: result.unknown,
        ).toJson(),
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
