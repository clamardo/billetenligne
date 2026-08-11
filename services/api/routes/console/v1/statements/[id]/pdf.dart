import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/documents/pdf_response.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/statements/{id}/pdf` — the statement as a document
/// (`04-payments.md` §6.2).
///
/// The same figures the console already renders, in the form an accountant
/// files and a bank accepts. Rendered here rather than in the console because
/// the server is the only place prose is produced (ADR-0008), and because a
/// document generated on four different clients is four documents.
///
/// **Another operator's statement id is a 404, by policy rather than by a
/// check in this handler.** The read runs under the caller's tenancy, 0018
/// gives an operator's connection SELECT on their own `payout_runs` and
/// nothing else, and a row that is not visible simply is not there. That is
/// what makes it hold against a handler written next year by somebody who
/// never read the migration.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.financeRead);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final run = await services.payouts.statement(
    runId: id,
    operatorId: scope.operatorId,
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
    operatorName: run.operatorName ?? scope.operatorId,
    // French unless the reader asked otherwise. §6.2 wants a French
    // commercial document, and this is a market whose tax authority reads
    // French — the English catalog exists for the operator's own bookkeeper,
    // not as a default.
    language: context.request.headers[BelHeaders.language] ?? 'fr',
    trace: trace,
  );
}
