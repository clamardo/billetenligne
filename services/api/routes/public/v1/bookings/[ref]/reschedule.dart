import 'dart:io';

import 'package:bel_api/src/application/ports/reschedule_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /public/v1/bookings/<ref>/reschedule` — where else they could go.
/// `POST /public/v1/bookings/<ref>/reschedule` — move them (§8.1).
///
/// **Every row is priced before selection.** §8.1's mock shows the fare
/// difference and the fee on each result line, and that is not decoration:
/// somebody scanning a list is comparing prices, and a screen that prices
/// only the row you tapped makes them tap five times to compare four
/// departures on a connection that drops.
///
/// The POST re-prices under the lock rather than trusting what the screen
/// was drawn from — the coach can fill, and the free window can close, while
/// a phone is in somebody's pocket.
Future<Response> onRequest(RequestContext context, String ref) async {
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
  final bookingRef = parsed.valueOrNull!.value;

  switch (context.request.method) {
    case HttpMethod.get:
      final options = await services.reschedules.options(
        bookingRef: bookingRef,
        userId: principal.userId,
        now: services.clock.now(),
      );
      if (options == null) return _notFound(trace);

      return Response.json(
        body: _optionsJson(options),
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
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

      final result = await services.reschedules.change(
        bookingRef: bookingRef,
        userId: principal.userId,
        toDepartureId: departureId,
        now: services.clock.now(),
      );
      if (result == null) return _notFound(trace);

      if (result.refusal case final refusal?) {
        return Response.json(
          // 409 throughout: each of these is the world having moved since the
          // screen was drawn, not a malformed request. A client that sees 400
          // goes looking for a bug in its own payload.
          statusCode: HttpStatus.conflict,
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
        body: ChangeAppliedDto(
          bookingRef: applied.bookingRef,
          departureId: applied.departureId,
          departsAt: applied.departsAt,
          seatLabels: applied.seatLabels,
        ).toJson(),
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Map<String, Object?> _optionsJson(ChangeOptions options) => ChangeOptionsDto(
  bookingRef: options.bookingRef,
  originCity: options.originCity,
  destinationCity: options.destinationCity,
  seatsNeeded: options.seatsNeeded,
  currentDepartureId: options.currentDepartureId,
  currentDepartsAt: options.currentDepartsAt,
  paidFare: options.paidFare,
  options: [
    for (final option in options.options)
      ChangeOptionDto(
        departureId: option.departureId,
        departsAt: option.departsAt,
        arrivesAt: option.arrivesAt,
        fare: option.fare,
        seatsAvailable: option.seatsAvailable,
        fee: option.quote?.fee,
        fareDifference: option.quote?.fareDifference,
        owed: option.quote?.owed,
        refusalCode: option.refusal?.code,
        refusalParams: option.refusal?.params ?? const {},
      ),
  ],
  policyLines: options.policy.describe(),
  involuntary: options.involuntary,
  refusalCode: options.refusal?.code,
  refusalParams: options.refusal?.params ?? const {},
  pending: options.pending == null ? null : _orderDto(options.pending!),
).toJson();

/// One order on the wire. Shared with the order route next door so the shape
/// a traveller sees on the list and the shape they see after tapping cannot
/// drift apart.
ChangeOrderDto _orderDto(ChangeOrder order) => ChangeOrderDto(
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
);

Response _notFound(String trace) => Response.json(
  statusCode: HttpStatus.notFound,
  body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
