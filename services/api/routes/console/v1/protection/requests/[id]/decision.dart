import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import '../../index.dart';
import '../../requests.dart';

/// `POST /console/v1/protection/requests/<id>/decision` — accept or decline.
///
/// **Accepting applies the movement in the same transaction.** A request that
/// is accepted now and applied later leaves a window in which the receiving
/// operator sells the seats they have just promised, and the person who finds
/// out is a passenger at a door.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  // The receiving dispatcher's decision, not the finance office's: somebody
  // is standing at a gare waiting for an answer.
  final denied = Require.capability(context, Capability.disruptionDeclare);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final request = AgreementDecisionRequest.fromJson(body);

  if (request.decision != 'accept' && request.decision != 'decline') {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: ApiError(
        code: ErrorCode.badRequest,
        fieldErrors: {'decision': request.decision},
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final result = await services.protection.decideRequest(
    operatorId: scope.operatorId,
    requestId: id,
    decision: request.decision,
    actorUserId: context.read<Principal>().userId,
    now: services.clock.now(),
    reason: request.reason,
  );

  if (result.refusal case final refusal?) {
    return refusedAgreement(refusal, trace);
  }

  return Response.json(
    body: requestDto(result.request!).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}
