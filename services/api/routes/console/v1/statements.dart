import 'dart:io';

import 'package:bel_api/src/application/ports/payout_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/statements` — an operator's own payout statements.
///
/// Read-only, and that is the design rather than a limitation: 0018 gives an
/// operator's connection SELECT on `payout_runs` and no other privilege at
/// all. The party being paid does not get to move the row that pays them, and
/// enforcing that in a grant means it holds against any code path, including
/// one written next year by somebody who never read the migration.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.financeRead);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final statements = await services.payouts.statementsFor(scope.operatorId);

  return Response.json(
    body: {
      'items': [for (final run in statements) _dto(run).toJson()],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

PayoutRunDto _dto(PayoutRun run) => PayoutRunDto(
  id: run.id,
  operatorId: run.statement.operatorId,
  periodStart: run.statement.from,
  periodEnd: run.statement.to,
  onlineSalesCount: run.statement.onlineSalesCount,
  onlineGross: run.statement.onlineGross,
  cashSalesCount: run.statement.cashSalesCount,
  cashGross: run.statement.cashGross,
  commission: run.statement.commission,
  serviceFees: run.statement.serviceFees,
  refunds: run.statement.refunds,
  payable: run.statement.payable,
  tills: run.statement.tills,
  net: run.statement.net,
  state: run.state,
  preparedAt: run.preparedAt,
  approvedAt: run.approvedAt,
  paidAt: run.paidAt,
  destination: run.destination,
  reference: run.reference,
);
