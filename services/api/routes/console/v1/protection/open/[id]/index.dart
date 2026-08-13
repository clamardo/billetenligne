import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import '../../index.dart';
import '../../open.dart';

/// `DELETE /console/v1/protection/open/<id>` — take the call back.
///
/// Only the sender can, and only while it is open: withdrawing one somebody
/// has just answered would be undoing a movement that has already reissued
/// tickets, and a dispatcher who is a second too late deserves to be told
/// that rather than to be obeyed.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.delete) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.disruptionDeclare);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final result = await services.protection.withdrawCall(
    operatorId: scope.operatorId,
    callId: id,
    actorUserId: context.read<Principal>().userId,
  );

  if (result.refusal case final refusal?) {
    return refusedAgreement(refusal, trace);
  }

  return Response.json(
    body: callDto(result.call!).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
