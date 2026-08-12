import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/alerts` — everything this traveller is still waiting on.
///
/// Soonest coach first, because an alert for tomorrow morning is the one
/// about to stop mattering and an alert for next month can wait a scroll.
///
/// Exists so the app can show "you are waiting on this one" on a departure it
/// is already drawing, without a request per row. It is also the only way
/// somebody can find an alert they set weeks ago and no longer want.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();

  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final services = context.read<Services>();
  final account = await services.directory.byAuthUid(principal.authUid);
  if (account == null) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final waiting = await services.seatAlerts.waitingFor(account.id);

  return Response.json(
    body: {
      'items': [
        for (final alert in waiting)
          SeatAlertDto(
            id: alert.id,
            departureId: alert.departureId,
            seatsWanted: alert.seatsWanted,
            createdAt: alert.createdAt,
            notifiedAt: alert.notifiedAt,
          ).toJson(),
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'no-store',
    },
  );
}
