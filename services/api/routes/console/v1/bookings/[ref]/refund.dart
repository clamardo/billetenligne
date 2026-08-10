import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/bookings/{ref}/refund` — what cancelling would give back.
/// `POST /console/v1/bookings/{ref}/refund` — do it.
///
/// The GET is the sentence a vendor reads aloud before anybody agrees to
/// anything, and it is computed by the same `quoteRefund` the POST executes a
/// moment later (ADR-0004). A quote that came from different code than the
/// payout is how "you said 8 100" becomes an argument at a counter.
///
/// **The terms are the ones the booking was sold under**, never the
/// operator's current policy. That is ADR-0015 rule 1, and it is enforced by
/// the join rather than by remembering.
///
/// The POST needs a **reason**, like every other act in this system that
/// moves money on somebody's behalf. It is written to the refund row and it
/// is the only thing that can answer "why did we give this person money?" six
/// weeks later.
Future<Response> onRequest(RequestContext context, String ref) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;
  final clock = context.read<Services>().clock;

  switch (context.request.method) {
    case HttpMethod.get:
      // Quoting is reading. A vendor who may see a booking may tell somebody
      // what their terms say — refusing that would push the answer onto a
      // phone call to the owner.
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final offer = await console.quoteRefund(
        operatorId: scope.operatorId,
        bookingRef: ref,
        now: clock.now(),
      );
      if (offer == null) return _notFound(trace);

      return Response.json(
        body: _offerJson(offer),
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.bookingRefund);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final reason = body['reason'];
      if (reason is! String || reason.trim().length < 3) {
        return _badRequest(trace, 'reason');
      }

      final issued = await console.refundBooking(
        operatorId: scope.operatorId,
        bookingRef: ref,
        actorUserId: context.read<Principal>().userId,
        reason: reason.trim(),
        now: clock.now(),
      );

      // Null means the booking cannot be refunded, and the honest way to say
      // which reason is to re-quote rather than to invent a second vocabulary
      // for the same set of refusals.
      if (issued == null) {
        final offer = await console.quoteRefund(
          operatorId: scope.operatorId,
          bookingRef: ref,
          now: clock.now(),
        );
        if (offer == null) return _notFound(trace);
        return Response.json(
          statusCode: HttpStatus.conflict,
          body: ApiError(
            code: offer.failureCode ?? ErrorCode.refundNotPossible,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response.json(
        statusCode: HttpStatus.created,
        body: {
          'id': issued.id,
          'bookingRef': issued.bookingRef,
          'amount': Wire.money(issued.amount),
          'destination': issued.destination,
          'state': issued.state,
          // The six characters the traveller shows at the counter. Absent for
          // a destination that does not end at one.
          if (issued.claimCode != null) 'claimCode': issued.claimCode,
          if (issued.claimExpiresAt != null)
            'claimExpiresAt': issued.claimExpiresAt!.toUtc().toIso8601String(),
        },
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Map<String, Object?> _offerJson(RefundOffer offer) {
  final quote = offer.quote;
  return {
    'bookingRef': offer.bookingRef,
    'state': offer.state,
    'departsAt': offer.departsAt.toUtc().toIso8601String(),
    'fare': Wire.money(offer.fare),
    'serviceFee': Wire.money(offer.serviceFee),
    'refundable': quote == null ? null : Wire.money(quote.refundable),
    'retained': quote == null ? null : Wire.money(quote.retained),
    'rateBps': quote?.rateBps,
    'destination': quote?.destination.name,
    'processingHours': quote?.processingWindow.inHours,
    'involuntary': quote?.involuntary ?? false,
    // The terms themselves, so the console renders the same sentences the
    // traveller was shown before paying rather than a second description of
    // them.
    'policyName': offer.policyName,
    'policyLines': offer.policy?.describe(),
    'failureCode': offer.failureCode,
  };
}

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
