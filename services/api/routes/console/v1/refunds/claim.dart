import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /console/v1/refunds/claim` — pay a claim out of the drawer.
///
/// ADR-0015 rule 5: an operator who refunds in cash is legitimate, and the
/// refund then becomes a **claim** the traveller collects in person. This is
/// the counter half of it.
///
/// Two things are load-bearing.
///
///   * **The station.** The money leaves a specific drawer, counted at the
///     end of a shift by the person who closed it. A vendor is scoped to
///     their station for exactly this reason, and the check is the same one
///     the sale path makes.
///   * **Single use, by statement.** The state moves `claim_issued → claimed`
///     in the same UPDATE that reads it, so two vendors scanning one code at
///     two windows cannot both hand over cash. A SELECT-then-UPDATE here
///     would lose that race, and what it would lose is money.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // Paying out cash, not reading a policy. `bookingRefund` is the capability
  // a vendor holds and `bookingRead` deliberately is not.
  final denied = Require.capability(context, Capability.bookingRefund);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;

  final claimCode = body['claimCode'];
  if (claimCode is! String || claimCode.trim().length < 4) {
    return _badRequest(trace, 'claimCode');
  }

  final stationId = body['stationId'];
  if (stationId is! String || stationId.isEmpty) {
    return _badRequest(trace, 'stationId');
  }

  final wrongStation = Require.station(context, stationId);
  if (wrongStation != null) return wrongStation;

  final claimed = await services.console.claimRefund(
    operatorId: scope.operatorId,
    claimCode: claimCode,
    stationId: stationId,
    actorUserId: context.read<Principal>().userId,
    now: services.clock.now(),
  );

  // One answer for "no such code", "already collected" and "expired". A
  // counter that distinguishes them is a counter that tells somebody holding
  // a guessed code which guess was closer.
  if (claimed == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: ApiError(
        code: ErrorCode.refundClaimNotOpen,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: {
      'id': claimed.id,
      'bookingRef': claimed.bookingRef,
      'amount': Wire.money(claimed.amount),
      'stationId': claimed.stationId,
    },
    headers: {BelHeaders.traceId: trace},
  );
}

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
