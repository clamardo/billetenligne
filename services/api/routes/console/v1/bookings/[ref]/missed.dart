import 'dart:io';

import 'package:bel_api/src/application/ports/reschedule_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/bookings/{ref}/missed` — later coaches for a passenger
/// whose own coach has gone.
/// `POST /console/v1/bookings/{ref}/missed` — put them on one.
///
/// **This is a counter screen and deliberately not in the app.** Somebody who
/// missed a coach is standing in front of an agent with a printed ticket, and
/// whether to honour it is the company's decision to take in person. It is
/// also the only place the money can be collected today: the fee is cash
/// across a counter, into a drawer somebody counts at the end of a shift.
///
/// The list crosses **routes, not companies**. Every later departure this
/// operator runs between the same two cities is offered — which is what lets
/// the 09:30 from the other gare appear, since a company's two Brazzaville
/// terminals are two rows in `routes` and a passenger does not care which.
/// Another company is refused: that is a new purchase, not a transfer, and
/// pretending otherwise would move a fare between two operators' books.
///
/// The GET is quoted by the same `quoteMissed` the POST executes moments
/// later (ADR-0004), and the POST re-quotes under the lock — at a counter,
/// the gap between reading a price aloud and taking the money is minutes.
Future<Response> onRequest(RequestContext context, String ref) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();
  final now = services.clock.now();

  switch (context.request.method) {
    case HttpMethod.get:
      // Reading is reading. An agent who may see a booking may tell somebody
      // what their company's terms say about it.
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final options = await services.reschedules.missedOptions(
        bookingRef: ref,
        operatorId: scope.operatorId,
        now: now,
      );
      if (options == null) return _notFound(trace);

      return Response.json(
        body: _optionsJson(options).toJson(),
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      // The same authority as any other change to somebody's journey. Not
      // `disruption.declare`: this is one passenger at a counter, not forty
      // on a broken-down coach.
      final denied = Require.capability(context, Capability.bookingReschedule);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final departureId = body['departureId'];
      if (departureId is! String || departureId.isEmpty) {
        return _badRequest(trace, 'departureId');
      }

      final stationId = body['stationId'];
      if (stationId != null && stationId is! String) {
        return _badRequest(trace, 'stationId');
      }

      // A vendor scoped to their own counters cannot put money in another
      // station's drawer. The till is where their shift is.
      if (stationId is String && !scope.coversStation(stationId)) {
        return Response.json(
          statusCode: HttpStatus.forbidden,
          body: ApiError(code: ErrorCode.forbidden, traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      final outcome = await services.reschedules.moveMissed(
        bookingRef: ref,
        operatorId: scope.operatorId,
        toDepartureId: departureId,
        actorUserId: context.read<Principal>().userId,
        now: now,
        stationId: stationId as String?,
      );
      if (outcome == null) return _notFound(trace);

      if (outcome.refusal case final refusal?) {
        return Response.json(
          statusCode: HttpStatus.conflict,
          body: ApiError(
            code: refusal.code,
            params: refusal.params,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      final moved = outcome.moved!;
      return Response.json(
        statusCode: HttpStatus.created,
        body: MissedTransferDto(
          bookingRef: moved.bookingRef,
          departureId: moved.departureId,
          departsAt: moved.departsAt,
          seatLabels: moved.seatLabels,
          paid: moved.paid,
          stationName: moved.stationName,
          boardingNotes: moved.boardingNotes,
        ).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

MissedOptionsDto _optionsJson(MissedOptions options) => MissedOptionsDto(
  bookingRef: options.bookingRef,
  originCity: options.originCity,
  destinationCity: options.destinationCity,
  seatsNeeded: options.seatsNeeded,
  departedAt: options.departedAt,
  paidFare: options.paidFare,
  // Keys, never sentences (ADR-0008). The agent reads the company's promise
  // aloud in whichever language the console is set to.
  terms: options.policy.describe(),
  fromStationName: options.fromStationName,
  involuntary: options.involuntary,
  refusalCode: options.refusal?.code,
  options: [
    for (final o in options.options)
      MissedOptionDto(
        departureId: o.departureId,
        departsAt: o.departsAt,
        arrivesAt: o.arrivesAt,
        fare: o.fare,
        seatsAvailable: o.seatsAvailable,
        stationName: o.stationName,
        boardingNotes: o.boardingNotes,
        sameStation: o.sameStation,
        fee: o.quote?.fee,
        fareDifference: o.quote?.fareDifference,
        owed: o.quote?.owed,
        refusalCode: o.refusal?.code,
      ),
  ],
);

Response _notFound(String trace) => Response.json(
  statusCode: HttpStatus.notFound,
  body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
