import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import '../index.dart';

/// `POST /console/v1/protection/<id>/decision` — accept · decline · suspend ·
/// resume · end.
///
/// One route for five decisions, because the rule they share is the one worth
/// enforcing in one place: **the party that wrote the terms cannot be the
/// party that agrees to them** (`08-disruption.md` §5). The server checks it
/// against the stored `proposed_by`, never against what the client sends.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.protectionManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final request = AgreementDecisionRequest.fromJson(body);

  const decisions = {'accept', 'decline', 'suspend', 'resume', 'end'};
  if (!decisions.contains(request.decision)) {
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

  final result = await services.protection.decide(
    operatorId: scope.operatorId,
    agreementId: id,
    decision: request.decision,
    actorUserId: context.read<Principal>().userId,
    reason: request.reason,
  );

  if (result.refusal case final refusal?) {
    return refusedAgreement(refusal, trace);
  }

  return Response.json(
    body: agreementDto(result.agreement!).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}
