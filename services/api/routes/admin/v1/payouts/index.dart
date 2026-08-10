import 'dart:io';

import 'package:bel_api/src/application/ports/payout_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/payouts` — what is waiting for a second pair of eyes.
/// `POST /admin/v1/payouts` — prepare one operator's week.
///
/// A work queue rather than a report (`04-payments.md` §6.2): everything
/// prepared and not yet paid, oldest first, with the number on it. A payout
/// sitting unapproved for three days is an operator wondering where their
/// money is, and the only way anybody finds out is by seeing the row.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  return switch (context.request.method) {
    HttpMethod.get => _queue(services, scope, trace),
    HttpMethod.post => _prepare(context, services, scope, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _queue(
  Services services,
  PlatformScope scope,
  String trace,
) async {
  // Reading the queue needs only finance.read; moving anything on it needs
  // payout.approve. Our own analyst should be able to answer "has Océan du
  // Nord been paid?" without holding the authority to pay them.
  if (!scope.can(Capability.financeRead)) {
    return _forbidden(trace);
  }

  final pending = await services.payouts.pending(
    actorUserId: scope.actorUserId,
  );

  return Response.json(
    body: {
      'items': [for (final run in pending) _dto(run).toJson()],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Future<Response> _prepare(
  RequestContext context,
  Services services,
  PlatformScope scope,
  String trace,
) async {
  if (!scope.can(Capability.payoutApprove)) return _forbidden(trace);

  final PreparePayoutRequest request;
  try {
    request = PreparePayoutRequest.fromJson(
      await context.request.json() as Map<String, Object?>,
    );
  } on WireFormatException catch (e) {
    return _badRequest(trace, e.field);
  } on FormatException {
    return _badRequest(trace, 'body');
  }

  final result = await services.payouts.prepare(
    operatorId: request.operatorId,
    from: request.periodStart,
    to: request.periodEnd,
    actorUserId: scope.actorUserId,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.created,
      body: _dto(value).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    Err(:final failure) => refusedPayout(failure, trace),
  };
}

/// The refusal, as a status. A conflict for everything except "no such
/// operator": the request was well formed and the world refused it.
Response refusedPayout(PayoutRefusal failure, String trace) =>
    switch (failure) {
      UnknownPayout() => Response.json(
        statusCode: HttpStatus.notFound,
        body: Problem.notFound(traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
      _ => Response.json(
        statusCode: HttpStatus.conflict,
        body: ApiError(code: failure.code, traceId: trace).toJson(),
        headers: {BelHeaders.traceId: trace},
      ),
    };

PayoutRunDto _dto(PayoutRun run) => payoutDto(run);

/// Shared with the single-run route, so a statement reads identically
/// wherever it is fetched from.
PayoutRunDto payoutDto(PayoutRun run) => PayoutRunDto(
  id: run.id,
  operatorId: run.statement.operatorId,
  operatorName: run.operatorName,
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

Response _forbidden(String trace) => Response.json(
  statusCode: HttpStatus.forbidden,
  body: Problem.forbidden(traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
