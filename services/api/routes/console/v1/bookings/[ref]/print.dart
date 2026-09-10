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

/// `POST /console/v1/bookings/{ref}/print` — a URL the till can open, now.
///
/// The counter's other half. `ticket-link` answers the customer who has an
/// address; this answers the one who does not, which in this market is most
/// of them: cash, no app, no smartphone, and a coach at half past five.
///
/// **This is the one endpoint that hands the console a token**, and the
/// reasoning for the exception is in the port. Kept as small as it goes: a
/// link that lives twenty minutes, is never sent anywhere, and is recorded on
/// its own channel so an operator asking who printed a ticket twice gets an
/// answer.
///
/// **The format is the caller's, not the operator's setting.** The same
/// agency prints three-to-a-page all morning and a full sheet for the
/// customer who asked for a receipt; that is a decision made at the printer.
/// The operator's saved design decides how it *looks*, which is a different
/// question and lives on `ticket_designs`.
Future<Response> onRequest(RequestContext context, String ref) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // The same authority as selling. Printing is a till action, and a printed
  // ticket boards a coach.
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

  Map<String, Object?> body;
  try {
    body = await context.request.json() as Map<String, Object?>;
  } on FormatException {
    body = const {};
  } on TypeError {
    body = const {};
  }

  // An unknown format is a 400 naming the field, never a silent fallback: a
  // vendor who asked for a full page and got three small ones has a customer
  // in front of them and no idea why.
  final format = (body['format'] as String?)?.trim();
  final known = TicketFormat.values.any((f) => f.name == format);
  if (format != null && !known) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'format', 'value': format},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final minted = await services.ticketLinks.mintForPrint(
    operatorId: scope.operatorId,
    bookingRef: booking.value,
    format: format ?? TicketFormat.boardingPass.name,
    byUserId: context.read<Principal>().userId,
    now: services.clock.now(),
  );

  return switch (minted) {
    Ok(:final value) => Response.json(
      body: value.toJson(),
      headers: {
        BelHeaders.traceId: trace,
        // A live ticket. No cache but the browser about to open it.
        HttpHeaders.cacheControlHeader: 'private, no-store',
        'Referrer-Policy': 'no-referrer',
      },
    ),
    Err(:final failure) => switch (failure) {
      UnknownBooking() => Response.json(
        statusCode: HttpStatus.notFound,
        body: Problem.notFound(traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      // Well formed, and the world refused it: a reservation nobody has paid
      // for has no ticket to print.
      _ => Response.json(
        statusCode: HttpStatus.conflict,
        body: ApiError(code: failure.code, traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
    },
  };
}
