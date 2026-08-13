import 'dart:io';

import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart';

/// `GET` the open calls this operator can see · `POST` to broadcast one
/// (`08-disruption.md` §5).
///
/// The list is one payload rather than two, and carries `receiving` beside
/// the rows: an empty inbox has to be able to say which kind of empty it is,
/// because *nobody needs help right now* and *you never opted in* are the
/// same zero rows and completely different screens.
///
/// Broadcasting needs `disruption.declare`, not `protection.manage` — the
/// same split the agreement routes make, for the same reason. Calling for
/// help at 05:40 is the dispatcher's decision; agreeing standing terms is
/// somebody else's, on a different day.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final result = await services.protection.openCalls(scope.operatorId);
      return Response.json(
        body: OpenCallsDto(
          receiving: result.receiving,
          calls: [for (final c in result.calls) callDto(c)],
        ).toJson(),
        headers: {
          BelHeaders.traceId: trace,
          // A live inbox of who needs help in the next two hours. Caching it
          // for even a minute is caching the reason it exists.
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.disruptionDeclare);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final request = OpenCallBody.fromJson(body);

      // Clamped, and the client does not get to keep a call live all week:
      // the window is how long every other console in the country carries
      // this row. Between a quarter of an hour and half a day.
      final minutes = (request.windowMinutes ?? 120).clamp(15, 720);

      final result = await services.protection.openCall(
        operatorId: scope.operatorId,
        departureId: request.departureId,
        actorUserId: context.read<Principal>().userId,
        now: services.clock.now(),
        window: Duration(minutes: minutes),
        note: request.note,
      );

      if (result.refusal case final refusal?) {
        return refusedAgreement(refusal, trace);
      }

      return Response.json(
        statusCode: HttpStatus.created,
        body: callDto(result.call!).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

OpenCallDto callDto(OpenCallView view) => OpenCallDto(
  id: view.id,
  sendingOperatorName: view.sendingOperatorName,
  weOpened: view.weOpened,
  fromDepartureId: view.fromDepartureId,
  originCity: view.originCity,
  destinationCity: view.destinationCity,
  seatsRequested: view.seatsRequested,
  rebillPerSeat: view.rebillPerSeat,
  state: view.state,
  openedAt: view.openedAt,
  expiresAt: view.expiresAt,
  note: view.note,
  departsAt: view.departsAt,
  closedAt: view.closedAt,
);
