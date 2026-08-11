import 'dart:io';

import 'package:bel_api/src/application/ports/passenger_choices.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/bookings/<ref>/options` — the passenger's own choice
/// (`08-disruption.md` §3.2).
///
/// The option most systems never build, and the reason to build it is not
/// kindness: a seat released by somebody who would rather take the 16:00 goes
/// back into the pool for somebody still standing at the roadside. Forty-two
/// people choosing for themselves cover more of each other than any
/// dispatcher plan does.
///
/// Answers for a booking that is not disrupted too — with the journey, no
/// alternatives and `open: false` — because a passenger who follows a link
/// and finds nothing assumes the worst.
Future<Response> onRequest(RequestContext context, String ref) async {
  if (context.request.method != HttpMethod.get) {
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
  final choices = parsed.valueOrNull == null
      ? null
      : await services.choices.optionsFor(
          bookingRef: parsed.valueOrNull!.value,
          userId: principal.userId,
          now: services.clock.now(),
        );

  // Somebody else's reference reaches the same answer as one that does not
  // exist. The alternative is an endpoint that tells a stranger which
  // references are real.
  if (choices == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: ApiError(
        code: ErrorCode.bookingInvalidRef,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: choicesDto(choices).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      // Seat counts on the alternatives go stale in seconds, and a cached
      // screen offering a coach that filled is the one failure this endpoint
      // exists to avoid.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

TravelChoicesDto choicesDto(TravelChoices choices) => TravelChoicesDto(
  bookingRef: choices.bookingRef,
  options: [for (final o in choices.options) choiceDto(o)],
  deadline: choices.deadline,
  seatsNeeded: choices.seatsNeeded,
  originCity: choices.originCity,
  destinationCity: choices.destinationCity,
  open: choices.open,
  disruptionKind: choices.disruptionKind.isEmpty
      ? null
      : choices.disruptionKind,
  reasonKey: choices.reasonKey.isEmpty ? null : choices.reasonKey,
  note: choices.note,
);

TravelChoiceDto choiceDto(TravelChoice choice) => TravelChoiceDto(
  id: choice.id,
  kind: choice.kind.name,
  assigned: choice.assigned,
  departureId: choice.departureId,
  operatorName: choice.operatorName,
  departsAt: choice.departsAt,
  arrivesAt: choice.arrivesAt,
  seatsAvailable: choice.seatsAvailable,
  seatLabels: choice.seatLabels,
  amount: choice.amount,
  otherOperator: choice.otherOperator,
);
