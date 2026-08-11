import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/bookings/<ref>/reschedule/order` — hold a change and say
/// what it costs (§8.1).
///
/// The half of §8.1 that carries money. The plain POST next door moves a
/// booking that owes nothing; this one takes the seats on the target
/// departure, writes down what was quoted, and **moves nothing at all** until
/// the difference is captured. A change applied before the money lands is the
/// free journey an optimistically issued ticket would be (ADR-0005), one
/// departure further along.
///
/// A change that turns out to owe nothing at the lock comes back **already
/// applied**. The price fell between the list and the tap; refusing somebody
/// for that would be an insult with a 409 attached.
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

  final parsed = BookingRef.parse(ref);
  if (parsed.valueOrNull == null) return _notFound(trace);

  final body = await context.request.json() as Map<String, Object?>;
  final departureId = body['departureId'];
  if (departureId is! String || departureId.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'departureId'},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final result = await services.reschedules.reserveChange(
    bookingRef: parsed.valueOrNull!.value,
    userId: principal.userId,
    toDepartureId: departureId,
    now: services.clock.now(),
  );
  if (result == null) return _notFound(trace);

  if (result.refusal case final refusal?) {
    return Response.json(
      // 409, as next door: each of these is the world having moved since the
      // screen was drawn, not a malformed request.
      statusCode: HttpStatus.conflict,
      body: ApiError(
        code: refusal.code,
        params: refusal.params,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final order = result.order!;
  return Response.json(
    statusCode: HttpStatus.created,
    body: ChangeOrderDto(
      id: order.id,
      bookingId: order.bookingId,
      bookingRef: order.bookingRef,
      departureId: order.toDepartureId,
      departsAt: order.departsAt,
      owed: order.owed,
      expiresAt: order.expiresAt,
      state: order.state,
      fee: order.fee,
      fareDifference: order.fareDifference,
      seatLabels: order.seatLabels,
      applied: order.applied == null
          ? null
          : ChangeAppliedDto(
              bookingRef: order.applied!.bookingRef,
              departureId: order.applied!.departureId,
              departsAt: order.applied!.departsAt,
              seatLabels: order.applied!.seatLabels,
            ),
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Response _notFound(String trace) => Response.json(
  statusCode: HttpStatus.notFound,
  body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
