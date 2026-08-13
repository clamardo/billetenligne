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

/// `POST /console/v1/protection/open/<id>/answer` — take the call.
///
/// **First to accept wins, and winning is the same commit that moves the
/// passengers.** Two dispatchers reaching for the same forty-two people at
/// 06:04 is the normal case, not the edge one; the loser gets
/// `protection.call_closed` and their own coach is untouched.
///
/// The dispatcher's capability, like every other roadside decision here. A
/// company decides *whether* to be in this channel once, elsewhere, with
/// `protection.manage`; answering a particular call is the person who can see
/// how full the 07:30 actually is.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.disruptionDeclare);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final answer = AnswerCallBody.fromJson(body);

  final result = await services.protection.answerCall(
    operatorId: scope.operatorId,
    callId: id,
    replacementDepartureId: answer.replacementDepartureId,
    actorUserId: context.read<Principal>().userId,
    now: services.clock.now(),
    note: answer.note,
  );

  if (result.refusal case final refusal?) {
    return refusedAgreement(refusal, trace);
  }

  return Response.json(
    statusCode: HttpStatus.created,
    body: requestDto(result.request!).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}
