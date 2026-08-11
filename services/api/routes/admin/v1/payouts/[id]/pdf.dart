import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/documents/pdf_response.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/payouts/{id}/pdf` — the same document, from the queue.
///
/// The same bytes the operator gets, deliberately: a reviewer approving a
/// number and the company being paid must be looking at one document, or a
/// dispute six months from now becomes an argument about which print is
/// real.
///
/// `finance.read`, not `payout.approve`. Somebody answering "what did we send
/// Océan du Nord in August?" should not need the authority to pay them.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();

  if (!scope.can(Capability.financeRead)) {
    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final services = context.read<Services>();
  final run = await services.payouts.statement(
    runId: id,
    actorUserId: scope.actorUserId,
  );

  if (run == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return statementResponse(
    run: run,
    catalog: Services.translations,
    operatorName: run.operatorName ?? run.statement.operatorId,
    language: context.request.headers[BelHeaders.language] ?? 'fr',
    trace: trace,
  );
}
