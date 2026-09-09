import 'dart:io';

import 'package:bel_api/src/application/ports/trip_sharing.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/bookings/<ref>/journey` — where the passenger's own coach
/// has got to (J6).
///
/// The same three tiers of ADR-0014 the follower page has drawn since it
/// shipped, read **through the booking** rather than through a share token.
/// `followed_trip()` is keyed on a link, so the person with the most reason to
/// want this — somebody sitting on the coach, phone already in their hand —
/// has been the only one who could not see it unless they happened to mint a
/// link for a relative.
///
/// **The tier is in the payload and the screen is required to render it.**
/// This is the one endpoint in the product where drawing more confidence than
/// the data has would be a lie somebody acts on: a passenger who reads a
/// position when nobody has reported one rings the agency at Dolisie to ask
/// why the coach is not where the app says.
///
/// **Not on the ticket's own payload.** The ticket has to render with no
/// network at all (ADR-0003), so where the coach is cannot be part of it. It
/// is a separate call the screen draws when it arrives and simply omits when
/// it does not.
Future<Response> onRequest(RequestContext context, String ref) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();

  // Browsing needs no account (ADR-0013); this is not browsing. A journey
  // belongs to whoever bought the seat, and the row-level rule behind it is
  // keyed on their user id.
  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final parsed = BookingRef.parse(ref).valueOrNull;
  if (parsed == null) return _unknown(trace);

  final services = context.read<Services>();
  final journey = await services.sharing.journey(
    bookingRef: parsed.value,
    userId: principal.userId,
    now: services.clock.now(),
  );

  // One answer for "not yours", "not paid for", "cancelled" and "no such
  // reference". They are the same to this caller and the screen does the same
  // thing with all four, which is to draw the ticket and no road.
  if (journey == null) return _unknown(trace);

  return Response.json(
    body: _dto(journey).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      // A coach moves. A cached journey is the stale dot ADR-0014 refuses,
      // wearing a different hat.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

TripJourneyDto _dto(TripJourney journey) => TripJourneyDto(
  departsAt: journey.departsAt,
  arrivesAt: journey.arrivesAt,
  status: journey.status,
  tier: journey.progress.tier.name,
  progress: journey.progress.fraction,
  reportedAt: journey.progress.reportedAt,
  checkpointName: journey.progress.checkpointName,
  revisedDepartsAt: journey.revisedDepartsAt,
  stops: [
    for (final stop in journey.stops)
      JourneyStopDto(
        name: stop.name,
        offsetMinutes: stop.offsetMinutes,
        passedAt: stop.passedAt,
      ),
  ],
);

Response _unknown(String trace) => Response.json(
  statusCode: HttpStatus.notFound,
  body: ApiError(code: ErrorCode.bookingInvalidRef, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
