import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

import '../index.dart';

/// `POST /admin/v1/payouts/{id}/decision` — approve it, or send the money.
///
/// Two verbs behind one route because they are one control with a gap in the
/// middle (`04-payments.md` §6.2, ADR-0011). **Approving and preparing must
/// be different people** — the store refuses otherwise — and only an approved
/// run can be released. The release is the only call in this file that moves
/// money, and it posts the ledger transaction in the same transaction as it
/// marks the run paid.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();

  if (!scope.can(Capability.payoutApprove)) {
    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final PayoutDecisionRequest request;
  try {
    request = PayoutDecisionRequest.fromJson(
      await context.request.json() as Map<String, Object?>,
    );
  } on WireFormatException catch (e) {
    return _badRequest(trace, e.field);
  } on FormatException {
    return _badRequest(trace, 'body');
  }

  final services = context.read<Services>();

  final result = switch (request.decision) {
    'approve' => await services.payouts.approve(
      runId: id,
      actorUserId: scope.actorUserId,
    ),
    // A transfer nobody can find in a bank statement afterwards is a transfer
    // that gets paid twice, so the reference is required rather than optional.
    'release' when (request.reference ?? '').trim().isNotEmpty =>
      await services.payouts.release(
        runId: id,
        actorUserId: scope.actorUserId,
        reference: request.reference!.trim(),
        destination: request.destination,
      ),
    'release' => null,
    _ => null,
  };

  if (result == null) {
    return _badRequest(
      trace,
      request.decision == 'release' ? 'reference' : 'decision',
    );
  }

  return switch (result) {
    Ok(:final value) => Response.json(
      body: payoutDto(value).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    Err(:final failure) => refusedPayout(failure, trace),
  };
}

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
