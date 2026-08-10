import 'dart:io';

import 'package:bel_api/src/application/ports/disruption_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /console/v1/departures/{id}/rescue` — send a different coach.
///
/// Option ① of `08-disruption.md` §2.2, and the most common resolution to a
/// breakdown here: the operator's spare, or a coach pulled off another duty.
/// The bookings are untouched, the passengers keep their journey, and the
/// seats are remapped onto whatever the new coach actually has.
///
/// **A rescue coach must seat everybody.** A swap that seats thirty-nine of
/// forty-two is three people who find out at the door, and there is nowhere
/// to put them yet — that is the re-accommodation plan (§2.2 options ②③),
/// which is not built. So a coach that is too small is a 409 naming how many
/// are short, and the dispatcher finds a bigger one.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();

  final denied = Require.capability(context, Capability.disruptionDeclare);
  if (denied != null) return denied;

  final RescueCoachRequest request;
  try {
    request = RescueCoachRequest.fromJson(
      await context.request.json() as Map<String, Object?>,
    );
  } on WireFormatException catch (e) {
    return _badRequest(trace, e.field);
  } on FormatException {
    return _badRequest(trace, 'body');
  }

  final services = context.read<Services>();
  final scope = context.read<TenantScope>();

  final result = await services.disruptions.assignRescueCoach(
    operatorId: scope.operatorId,
    departureId: id,
    vehicleId: request.vehicleId,
    actorUserId: context.read<Principal>().userId,
    now: services.clock.now(),
    note: request.note,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: RescueAppliedDto(
        departureId: value.departureId,
        registration: value.registration,
        moves: [
          for (final move in value.remap.moves)
            SeatMoveDto(from: move.from, to: move.to),
        ],
        passengersTold: value.passengersTold,
        ticketsReissued: value.ticketsReissued,
        holdsReleased: value.holdsReleased,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    Err(:final failure) => _refused(failure, trace),
  };
}

Response _refused(DeclarationRefusal failure, String trace) =>
    switch (failure) {
      UnknownDeparture() => Response.json(
        statusCode: HttpStatus.notFound,
        body: Problem.notFound(traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      // The count is the point of the refusal: "three short" tells a dispatcher
      // which coach to look for next, and "no" does not.
      CannotSeatEverybody(:final short) => Response.json(
        statusCode: HttpStatus.conflict,
        body: ApiError(
          code: failure.code,
          params: {'short': short},
          traceId: trace,
        ).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      _ => Response.json(
        statusCode: HttpStatus.conflict,
        body: ApiError(code: failure.code, traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
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
