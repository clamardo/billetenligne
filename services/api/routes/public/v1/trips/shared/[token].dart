import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/trips/shared/{token}` — what a follower is shown
/// (ADR-0014 §2).
///
/// **Anonymous, and that is the whole point.** The person reading this holds
/// no account, may never become a customer, and is on a phone we know nothing
/// about. Requiring a sign-in to see whether a coach has passed Dolisie would
/// turn a two-second answer into an install.
///
/// Everything in the answer is a fact about a *coach*. No seat, no reference,
/// no fare, no phone number — and the type cannot carry them, because the SQL
/// function behind this returns those columns and no others.
///
/// A revoked link, an expired one and a token nobody ever issued all get the
/// same 404. Distinguishing them would tell whoever holds a dead link that it
/// was once real and that somebody took it away, which is a conversation the
/// traveller did not ask to start.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final trip = await services.sharing.follow(
    token: token,
    now: services.clock.now(),
  );

  if (trip == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: FollowedTripDto(
      operatorName: trip.operatorName,
      routeCode: trip.routeCode,
      originCity: trip.originCity,
      destinationCity: trip.destinationCity,
      departsAt: trip.departsAt,
      arrivesAt: trip.arrivesAt,
      status: trip.status,
      tier: trip.progress.tier.name,
      progress: trip.progress.fraction,
      expiresAt: trip.expiresAt,
      reportedAt: trip.progress.reportedAt,
      checkpointName: trip.progress.checkpointName,
      disruptionKind: trip.disruptionKind,
      disruptionCauseKey: trip.disruptionCause == null
          ? null
          : 'enum.DisruptionCause.${trip.disruptionCause}',
      disruptionNote: trip.disruptionNote,
      revisedDepartsAt: trip.revisedDepartsAt,
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      // Sixty seconds, matching the page's own poll. Long enough that a
      // hundred followers of one departure are a hundred cached reads at the
      // edge; short enough that "passé Dolisie" arrives while it still
      // matters.
      HttpHeaders.cacheControlHeader: 'public, max-age=60',
    },
  );
}
