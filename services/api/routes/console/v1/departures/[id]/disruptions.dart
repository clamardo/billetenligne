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

/// `POST /console/v1/departures/{id}/disruptions` — declare one.
///
/// The whole dispatcher flow in `08-disruption.md` §2.1 arrives here: four
/// large targets on a phone, a cause, and at most one extra field. Everything
/// else — which bookings become involuntary, what the departure now reads as,
/// who gets told — is derived on the way through, because a form that asked
/// those questions at a roadside would be a form answered wrongly.
///
/// It is **not idempotent by key**, and that is deliberate. A second
/// declaration on the same departure is a real thing that happens — a
/// breakdown, then a swap an hour later — so it supersedes rather than
/// deduplicates. What protects the passenger from a double message is the
/// outbox dedupe key, which is per *disruption*.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();

  // Its own capability, held by dispatchers and owners and not by a counter
  // agent. Cancelling a departure and telling forty-two people about it is
  // not the same authority as selling a seat.
  final denied = Require.capability(context, Capability.disruptionDeclare);
  if (denied != null) return denied;

  final DeclareDisruptionRequest request;
  try {
    request = DeclareDisruptionRequest.fromJson(
      await context.request.json() as Map<String, Object?>,
    );
  } on WireFormatException catch (e) {
    return _badRequest(trace, e.field);
  } on FormatException {
    return _badRequest(trace, 'body');
  }

  final services = context.read<Services>();
  final scope = context.read<TenantScope>();

  // The half of the rules that can be judged from the request alone, checked
  // before a transaction is opened — and by the domain rather than by a copy
  // of it here (ADR-0004). The rest need the departure's scheduled time and
  // are checked where it has been read.
  final early = refuseWithoutTheDeparture(
    kind: request.kind,
    now: services.clock.now(),
    revisedDepartsAt: request.revisedDepartsAt,
    estimatedResolution: request.estimatedResolution,
  );
  if (early != null) return _refused(DeclarationInvalid(early), trace);

  final result = await services.disruptions.declare(
    operatorId: scope.operatorId,
    departureId: id,
    kind: request.kind,
    cause: request.cause,
    actorUserId: context.read<Principal>().userId,
    now: services.clock.now(),
    note: request.note,
    location: request.location,
    revisedDepartsAt: request.revisedDepartsAt,
    estimatedResolution: request.estimatedResolution,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: _declared(value).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    Err(:final failure) => _refused(failure, trace),
  };
}

DeclaredDisruptionDto _declared(DisruptionRecord record) =>
    DeclaredDisruptionDto(
      disruption: DisruptionDto(
        id: record.id,
        kind: record.disruption.kind,
        cause: record.disruption.cause,
        declaredAt: record.disruption.declaredAt,
        marksInvoluntary: record.marksInvoluntary,
        note: record.disruption.note,
        location: record.disruption.location,
        revisedDepartsAt: record.disruption.revisedDepartsAt,
        estimatedResolution: record.disruption.estimatedResolution,
        resolvedAt: record.resolvedAt,
      ),
      departureId: record.departureId,
      bookingsAffected: record.bookingsAffected,
      departureStatus: record.disruption.departureStatus,
    );

/// The domain's refusals are 400s: the request described something that is
/// not a declaration. The two store refusals are a 404 and a 409, because
/// they are facts about the departure rather than about the body.
Response _refused(DeclarationRefusal failure, String trace) =>
    switch (failure) {
      UnknownDeparture() => Response.json(
        statusCode: HttpStatus.notFound,
        body: Problem.notFound(traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      DepartureAlreadyArrived() => Response.json(
        statusCode: HttpStatus.conflict,
        body: ApiError(code: failure.code, traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      DeclarationInvalid() => Response.json(
        statusCode: HttpStatus.badRequest,
        body: ApiError(
          code: failure.code,
          params: failure.failure.params,
          traceId: trace,
        ).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      // The refusals only the rescue-coach route can produce. Listed rather
      // than left to a wildcard, so adding a third surface to this port makes
      // this switch fail to compile instead of answering 200 to a refusal.
      UnusableVehicle() || CannotSeatEverybody() => Response.json(
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
