import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `PUT` whether this operator receives open protection calls
/// (`08-disruption.md` §5).
///
/// `protection.manage` rather than `disruption.declare`, and this is the one
/// place the split runs the other way from the routes beside it: agreeing to
/// carry other companies' passengers is a standing commitment about what this
/// company is for, not a roadside decision. A dispatcher can call for help;
/// only the people who sign things can promise to answer.
///
/// Opting out does not withdraw calls already answered, and does not stop
/// this operator asking for help. Broadcasting and answering are two
/// decisions, and a company with one coach may honestly want only the first.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.put) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final denied = Require.capability(context, Capability.protectionManage);
  if (denied != null) return denied;

  final body = await context.request.json() as Map<String, Object?>;
  final wanted = ReceiveOpenCallsBody.fromJson(body);

  final receiving = await services.protection.receiveOpenCalls(
    operatorId: scope.operatorId,
    receiving: wanted.receiving,
    actorUserId: context.read<Principal>().userId,
  );

  return Response.json(
    body: ReceiveOpenCallsBody(receiving: receiving).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
