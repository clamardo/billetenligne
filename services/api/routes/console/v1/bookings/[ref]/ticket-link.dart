import 'dart:io';

import 'package:bel_api/src/application/ports/ticket_links.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /console/v1/bookings/{ref}/ticket-link` — send the customer their
/// ticket (ADR-0026).
///
/// The vendor's half of the answer to the person this market is full of: the
/// walk-in, who leaves the counter with a printed slip and no way to reach
/// their ticket if they lose it. One question at the till — *voulez-vous aussi
/// le recevoir?* — and an address.
///
/// **The response does not contain the link.** The token has not been minted
/// yet; the drain mints it in the transaction that composes the message, so
/// the plaintext exists in the message and in nothing else. A URL on a counter
/// screen would also be a ticket anybody behind the customer can photograph.
///
/// **A channel the market cannot send on is refused here**, where the vendor
/// is standing, rather than swallowed into a queue that never delivers. SMS
/// is built and off in this market until a sender number exists, and a
/// tick-box that silently does nothing is worse than no tick-box.
///
/// `DELETE` kills every live link on the booking — the customer who says they
/// forwarded it to the wrong person, and the one thing a vendor can do about
/// that in ten seconds.
Future<Response> onRequest(RequestContext context, String ref) async {
  final method = context.request.method;
  if (method != HttpMethod.post && method != HttpMethod.delete) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // The same authority as selling: this is the counter's own action, and the
  // person who took the money is the person who sends the ticket.
  final denied = Require.capability(context, Capability.bookingSell);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final services = context.read<Services>();
  final scope = context.read<TenantScope>();
  final booking = BookingRef.parse(ref).valueOrNull;

  if (booking == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  if (method == HttpMethod.delete) {
    final revoked = await services.ticketLinks.revoke(
      operatorId: scope.operatorId,
      bookingRef: booking.value,
      now: services.clock.now(),
    );
    return switch (revoked) {
      Ok() => Response(statusCode: HttpStatus.noContent),
      Err(:final failure) => _refused(failure, trace),
    };
  }

  final Map<String, Object?> body;
  try {
    body = await context.request.json() as Map<String, Object?>;
  } on FormatException {
    return _badRequest(trace, 'body');
  } on TypeError {
    return _badRequest(trace, 'body');
  }

  final channel = (body['channel'] as String?)?.trim().toLowerCase();
  if (channel != 'email' && channel != 'phone') {
    return _badRequest(trace, 'channel');
  }

  // The market decides what can be sent, not the console. Checked before the
  // adapter so the refusal is the same whether or not a database is attached.
  if (channel == 'phone' && !services.smsConfigured) {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: ApiError(
        code: const ChannelUnavailable().code,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final queued = await services.ticketLinks.queueSend(
    operatorId: scope.operatorId,
    bookingRef: booking.value,
    channel: channel!,
    sendTo: body['sendTo'] as String?,
    byUserId: context.read<Principal>().userId,
    now: services.clock.now(),
  );

  return switch (queued) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.accepted,
      body: {'channel': value.channel, 'sentTo': value.sentTo},
      headers: {
        BelHeaders.traceId: trace,
        // An address, read back to the customer at the till. Not a shared
        // cache's business.
        HttpHeaders.cacheControlHeader: 'private, no-store',
      },
    ),
    Err(:final failure) => _refused(failure, trace),
  };
}

Response _refused(LinkRefusal failure, String trace) => switch (failure) {
  UnknownBooking() => Response.json(
    statusCode: HttpStatus.notFound,
    body: Problem.notFound(traceId: trace).toJson(),
    headers: {BelHeaders.traceId: trace},
  ),
  // Well formed, and the world refused it: an unpaid reservation, a channel
  // this market cannot send on, nowhere to send it.
  _ => Response.json(
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
