import 'dart:io';

import 'package:bel_api/src/application/ports/seat_alerts.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `/public/v1/departures/{id}/alerts` — "tell me if a seat frees up".
///
///   POST   — start waiting, for a stated number of seats
///   DELETE — stop
///
/// Signed in only, and that is not a policy choice: the alert is a promise to
/// send somebody a message, so there has to be somebody to send it to. An
/// anonymous browser tapping this would be asking us to remember a phone
/// number we were never given.
///
/// **The alert holds nothing.** Nobody is in a queue and nobody has a claim;
/// when seats come back everybody waiting is told at once and the first to
/// pay gets them. That is the only promise a system selling the same
/// inventory to a whole market can actually keep at the coach door.
Future<Response> onRequest(RequestContext context, String id) async {
  final trace = context.read<String>();
  final principal = context.read<Principal>();

  if (principal.isAnonymous) {
    return _json(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace));
  }

  final services = context.read<Services>();
  final account = await services.directory.byAuthUid(principal.authUid);
  if (account == null) {
    return _json(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace));
  }

  return switch (context.request.method) {
    HttpMethod.post => _watch(context, services, id, account.id, trace),
    HttpMethod.delete => _forget(services, id, account.id, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _watch(
  RequestContext context,
  Services services,
  String departureId,
  String userId,
  String trace,
) async {
  final body = await context.request.json() as Map<String, Object?>;

  // Defaulted rather than required. One seat is what "tell me when it opens"
  // means to almost everybody, and refusing a body-less POST would make the
  // simplest possible call the one that fails.
  final wanted = body['seatsWanted'] as int? ?? 1;

  // Six is the party size the seat rules allow anywhere else in the system;
  // checked here so the constraint refuses nothing a handler could have
  // caught, and so the caller gets a code rather than a 500 from Postgres.
  if (wanted < 1 || wanted > 6) {
    return _json(
      HttpStatus.badRequest,
      ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'seatsWanted'},
        traceId: trace,
      ),
    );
  }

  final watched = await services.seatAlerts.watch(
    departureId: departureId,
    userId: userId,
    seatsWanted: wanted,
  );

  return watched.fold(
    (alert) => Response.json(
      statusCode: HttpStatus.created,
      body: _dto(alert).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    (failure) => _json(
      Problem.statusFor(failure.code),
      Problem.fromFailure(failure, traceId: trace),
    ),
  );
}

/// Always 204, even when there was nothing to withdraw. Somebody who taps
/// "no longer interested" twice has got what they wanted both times, and a
/// 404 on the second tap would be an error message about a success.
Future<Response> _forget(
  Services services,
  String departureId,
  String userId,
  String trace,
) async {
  await services.seatAlerts.forget(departureId: departureId, userId: userId);
  return Response(
    statusCode: HttpStatus.noContent,
    headers: {BelHeaders.traceId: trace},
  );
}

SeatAlertDto _dto(SeatAlert alert) => SeatAlertDto(
  id: alert.id,
  departureId: alert.departureId,
  seatsWanted: alert.seatsWanted,
  createdAt: alert.createdAt,
  notifiedAt: alert.notifiedAt,
);

Response _json(int status, ApiError error) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: error.traceId ?? ''},
);
