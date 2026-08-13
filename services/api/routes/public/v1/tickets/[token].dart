import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/tickets/{token}` — the ticket, to whoever holds the link
/// (ADR-0026).
///
/// **Anonymous, and that is the decision rather than an oversight.** The
/// person reading this bought at a counter, holds no account, and is on a
/// handset we know nothing about. A name-and-date-of-birth gate in front of it
/// would stop nobody — both are semi-public and shoulder-surfable — while
/// costing the customer the two minutes they do not have at a coach door.
/// What protects this is the token: 160 bits, single-purpose, expiring,
/// revocable, stored only as a hash.
///
/// The **booking reference is never accepted here**. Six characters is an
/// enumeration, not a credential.
///
/// A revoked link, an expired one and a token nobody ever issued get the same
/// 404. Distinguishing them tells whoever holds a dead link that it was once
/// real and that somebody took it away — a conversation the traveller did not
/// ask to start.
///
/// The QR strings in the answer are **static**: they cannot rotate in an inbox
/// or on a page. That is the printed ticket's own weakness and the control is
/// the same one — a seat boards once, which the scanner's redemption log
/// enforces (ADR-0007, ADR-0026).
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final ticket = await services.ticketLinks.open(
    token: token,
    now: services.clock.now(),
  );

  if (ticket == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: {
      'bookingRef': 'BEL-${ticket.bookingRef}',
      'state': ticket.state,
      'operatorName': ticket.operatorName,
      'operatorCode': ticket.operatorCode,
      'routeCode': ticket.routeCode,
      'originCity': ticket.originCity,
      'destinationCity': ticket.destinationCity,
      'departsAt': Wire.instant(ticket.departsAt),
      'arrivesAt': Wire.instant(ticket.arrivesAt),
      'status': ticket.status,
      'stationName': ticket.stationName,
      'stationNotes': ticket.stationNotes,
      'channel': ticket.channel,
      'expiresAt': Wire.instant(ticket.expiresAt),
      'seats': [
        for (final seat in ticket.seats)
          {
            'seatLabel': seat.seatLabel,
            'passengerName': seat.passengerName,
            'qr': seat.payload,
            'voided': seat.voided,
          },
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      // A ticket, with names on it and a QR that boards a coach. A shared
      // cache holding one is a shared cache handing it out.
      HttpHeaders.cacheControlHeader: 'private, no-store',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    },
  );
}
