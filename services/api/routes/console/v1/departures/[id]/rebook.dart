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

/// `POST /console/v1/departures/{id}/rebook` — move the passengers onto
/// another departure of the operator's own.
///
/// Option ② of `08-disruption.md` §2.2, and the answer when there is no spare
/// coach: the 14:00 has eighteen seats, so eighteen of the forty-two travel
/// today and the dispatcher finds something else for the rest.
///
/// **Partial coverage is a 201, not a 409.** "18 / 42" is the honest answer
/// and the one a dispatcher acts on; refusing anything short of everybody
/// would mean the tool can only help on the days it is not needed. Only a
/// replacement that can take nobody at all is refused.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();

  // The same authority as declaring the disruption. Moving forty-two people
  // onto a different coach is not a counter agent's decision.
  final denied = Require.capability(context, Capability.disruptionDeclare);
  if (denied != null) return denied;

  final RebookRequest request;
  try {
    request = RebookRequest.fromJson(
      await context.request.json() as Map<String, Object?>,
    );
  } on WireFormatException catch (e) {
    return _badRequest(trace, e.field);
  } on FormatException {
    return _badRequest(trace, 'body');
  }

  final services = context.read<Services>();
  final scope = context.read<TenantScope>();

  final result = await services.disruptions.rebookOnto(
    operatorId: scope.operatorId,
    departureId: id,
    replacementDepartureId: request.replacementDepartureId,
    actorUserId: context.read<Principal>().userId,
    now: services.clock.now(),
    note: request.note,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: RebookingAppliedDto(
        departureId: value.departureId,
        replacementDepartureId: value.replacementDepartureId,
        replacementDepartsAt: value.replacementDepartsAt,
        moved: [
          for (final party in value.moved)
            RebookedPartyDto(
              bookingId: party.bookingId,
              ref: party.ref,
              seatLabels: party.seatLabels,
            ),
        ],
        passengersMoved: value.passengersMoved,
        passengersLeft: value.passengersLeft,
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
      // Every one of these is a fact about the two departures — a different
      // road, one that is not later, one that is full. A 409 rather than a
      // 400: the request was well formed and the world refused it.
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
