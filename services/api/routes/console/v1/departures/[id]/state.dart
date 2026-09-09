import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /console/v1/departures/{id}/state` — what has happened to this coach.
///
/// The "close the departure" the business asked for, and the write that makes
/// three of `departure_status`'s six values reachable at last. `boarding` is
/// written by the first scan rather than here; this is the crew's own
/// statement — *we have left*, *we have arrived*.
///
/// **Closing stops new sales and nothing else.** It does not touch a ticket.
/// A passenger who boarded and is sitting down has a valid ticket by
/// definition, and a scan uploaded from a dead zone three hours after the
/// coach left is still accepted — the door happened while the coach was
/// there. What it does do is let go of every checkout still in flight, so
/// somebody halfway through paying is told to choose again rather than
/// sold a seat on a coach that is already on the RN1.
///
/// **Behind `departure.close`, and that is not enough on its own.** The port
/// additionally requires the caller to be rostered on *this* departure
/// (0049), because a capability alone would let any driver in the company
/// close any coach in it. A dispatcher holding `departure.manage` may close
/// one whose crew has no signal, which is the exception the office exists for.
///
/// **Cancelling is not available here.** It has to tell everybody on board,
/// mark their bookings involuntary and open the re-accommodation paths
/// (ADR-0016); a tap on a handset would do a quarter of that and leave the
/// rest undone. It is a disruption, and it has its own route next door.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.departureClose);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();

  final String? raw;
  try {
    final body = await context.request.json() as Map<String, Object?>;
    raw = body['state'] as String?;
  } on Object {
    return _badRequest(trace);
  }
  if (raw == null) return _badRequest(trace);

  // Parsed here rather than passed through as a string, so a typo cannot
  // reach the database as a state no screen and no policy knows about. An
  // unparseable name is still handed to the port as null: the refusal for it
  // belongs with the other five, in one table.
  final result = await context.read<Services>().console.setDepartureState(
    operatorId: scope.operatorId,
    departureId: id,
    state: DepartureState.byName(raw),
    actorUserId: context.read<Principal>().userId,
    actorMayManage: scope.capabilities.contains(Capability.departureManage),
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      body: {
        'state': value.state.name,
        'changed': value.changed,
        if (value.at != null) 'at': Wire.instant(value.at!),
        // The number a dispatcher is about to be asked about at the counter.
        'holdsReleased': value.holdsReleased,
      },
      headers: {BelHeaders.traceId: trace},
    ),
    Err(:final failure) => _refused(trace, failure),
  };
}

/// 409 throughout, and deliberately not 403 for [notCrew]: the caller holds
/// the capability, so this is not a permission they are missing. It is a
/// statement about a coach they are not on, and the sentence they need says
/// so rather than sending them to find an administrator.
Response _refused(String trace, DepartureTransitionRefusal refusal) =>
    Response.json(
      statusCode: HttpStatus.conflict,
      body: ApiError(
        code: switch (refusal) {
          DepartureTransitionRefusal.unknownState =>
            ErrorCode.departureUnknownState,
          DepartureTransitionRefusal.notCrew => ErrorCode.departureNotCrew,
          DepartureTransitionRefusal.cancelled => ErrorCode.departureCancelled,
          DepartureTransitionRefusal.alreadyClosed =>
            ErrorCode.departureHasLeft,
          DepartureTransitionRefusal.outOfOrder =>
            ErrorCode.departureOutOfOrder,
          DepartureTransitionRefusal.cancelIsADisruption =>
            ErrorCode.departureCancelIsADisruption,
        },
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );

Response _badRequest(String trace) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: const {'field': 'state'},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
