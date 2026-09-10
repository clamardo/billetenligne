import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `DELETE /console/v1/ticket_designs/{id}` — throw one away.
///
/// A design nobody uses is clutter on a screen an operator opens twice a
/// year, and clutter there is why the wrong one gets chosen at a till.
///
/// Deleting the default is allowed and deliberately not special-cased: the
/// starters are always there, and a counter with no saved design prints
/// `classicPass` in the operator's own hue. There is no state in which a
/// ticket cannot be printed.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.delete) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.vitrineManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();

  final removed = await context.read<Services>().ticketDesigns.remove(
    operatorId: scope.operatorId,
    id: id,
  );

  return removed
      ? Response(statusCode: HttpStatus.noContent)
      : Response.json(
          statusCode: HttpStatus.notFound,
          body: Problem.notFound(traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
}
