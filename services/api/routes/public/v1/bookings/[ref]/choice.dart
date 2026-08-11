import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/bookings/<ref>/choice` — the passenger takes one
/// (`08-disruption.md` §3.2).
///
/// One tap and it is done: the seats are taken on the new coach before the
/// old ones are released, the ticket is re-signed, and the seat they gave up
/// is on sale again for whoever is still standing at the roadside. That last
/// part is the whole argument for the screen.
///
/// A refusal here is always a sentence the passenger can act on — the coach
/// filled, the deadline passed, the party does not fit — because the person
/// reading it is not a dispatcher and has nobody to ask.
Future<Response> onRequest(RequestContext context, String ref) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final body = await context.request.json() as Map<String, Object?>;
  final optionId = body['optionId'];
  if (optionId is! String || optionId.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'optionId'},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final parsed = BookingRef.parse(ref);
  if (parsed.valueOrNull == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: ApiError(
        code: ErrorCode.bookingInvalidRef,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final result = await services.choices.choose(
    bookingRef: parsed.valueOrNull!.value,
    userId: principal.userId,
    optionId: optionId,
    now: services.clock.now(),
  );

  if (result.refusal case final refusal?) {
    return Response.json(
      // 409 throughout: every one of these is the world having changed since
      // the screen was drawn, not a malformed request. A client that sees
      // 400 goes looking for a bug in its own payload.
      statusCode: refusal is UnknownChoice
          ? HttpStatus.notFound
          : HttpStatus.conflict,
      body: ApiError(
        code: refusal.code,
        params: refusal.params,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final applied = result.applied!;
  return Response.json(
    body: ChoiceAppliedDto(
      bookingRef: applied.bookingRef,
      kind: applied.kind.name,
      departureId: applied.departureId,
      departsAt: applied.departsAt,
      seatLabels: applied.seatLabels,
      refunded: applied.refunded,
      claimCode: applied.claimCode,
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
