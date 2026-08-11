import 'dart:io';

import 'package:bel_api/src/application/ports/self_cancellation.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /public/v1/bookings/<ref>/cancellation` — what cancelling will do.
/// `POST /public/v1/bookings/<ref>/cancellation` — do it (§8.2).
///
/// The GET is the sentence somebody reads before they decide, and it is
/// computed by the same domain functions the POST executes a moment later
/// (ADR-0004). A quote that came from different code than the outcome is how
/// "the app said 8 100" becomes an argument nobody can settle.
///
/// **No reason field**, unlike the counter's refund. A vendor refunding
/// somebody else's booking has to answer "why did we give this person
/// money?" six weeks later; a traveller cancelling their own owes nobody an
/// explanation, and a mandatory free-text box would only collect "annulation"
/// eleven thousand times.
///
/// The interesting refusals are all 409: the coach left, a counter refunded
/// it first, a payment is still in flight. Every one of them is the world
/// having moved since the screen was drawn, not a malformed request.
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
      final offer = await services.cancellations.offer(
        bookingRef: bookingRef,
        userId: principal.userId,
        now: services.clock.now(),
      );
      // Somebody else's reference and a reference that does not exist are the
      // same answer, and neither costs a round trip to find out which.
      if (offer == null) return _notFound(trace);

      return Response.json(
        body: _offerJson(offer),
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final result = await services.cancellations.cancel(
        bookingRef: bookingRef,
        userId: principal.userId,
        now: services.clock.now(),
      );

      if (result == null) return _notFound(trace);

      if (result.refusal case final refusal?) {
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

      final done = result.done!;
      return Response.json(
        body: CancellationDoneDto(
          bookingRef: done.bookingRef,
          kind: done.kind.name,
          refunded: done.refunded,
          claimCode: done.claimCode,
          claimExpiresAt: done.claimExpiresAt,
          processingHours: done.processingWindow?.inHours,
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

Map<String, Object?> _offerJson(
  CancellationOffer offer,
) => CancellationOfferDto(
  bookingRef: offer.bookingRef,
  kind: offer.kind?.name,
  departsAt: offer.departsAt,
  originCity: offer.originCity,
  destinationCity: offer.destinationCity,
  seatCount: offer.seatCount,
  fare: offer.fare,
  serviceFee: offer.serviceFee,
  refundable: offer.quote?.refundable,
  retained: offer.quote?.retained,
  rateBps: offer.quote?.rateBps,
  // Only for money that is sent. A claim at a counter has no window — the
  // code works the moment it is on the screen — and quoting "sous 72 heures"
  // beside it would invent a wait that does not exist.
  processingHours: offer.kind == CancellationKind.toSource
      ? offer.quote?.processingWindow.inHours ??
            offer.policy?.processingWindow.inHours
      : null,
  givesNothingBack: offer.givesNothingBack,
  policyName: offer.policyName,
  // The terms themselves, so the app renders the same sentences it showed
  // before purchase rather than a second description of them.
  policyLines: offer.policy?.describe() ?? const [],
  refusalCode: offer.refusal?.code,
).toJson();

Response _notFound(String trace) => Response.json(
  statusCode: HttpStatus.notFound,
  body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
