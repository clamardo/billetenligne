import 'dart:io';

import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart' show adminOperatorDto;

/// `POST /admin/v1/operators/{id}/decision` — approve · activate · request
/// info · reject · suspend · reinstate.
///
/// One route for six outcomes rather than six routes, because they are one
/// decision with one shape: a lifecycle transition, a mandatory reason, and
/// an audit row written in the same transaction as the change.
///
/// Three things it refuses, and each is a real mistake rather than a
/// theoretical one:
///
///   * **an unknown decision name** — 400, rather than silently doing
///     nothing, because a client typo must not look like a successful review;
///   * **a decision this operator's state does not allow** — 409. Approving
///     something already active is not a no-op, it is a sign the reviewer is
///     looking at the wrong row, and two reviewers approving one application
///     at the same moment must produce one approval. The guard is in SQL too;
///   * **suspending without `platform.operator.suspend`** — 403. The
///     capability is checked per outcome, not per route: `operations` may
///     suspend, `viewer` may not, and both can read the same queue.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final request = OperatorDecisionRequest.fromJson(body);

  final decision = OperatorDecision.byName(request.decision);
  if (decision == null) {
    return _error(
      HttpStatus.badRequest,
      ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'decision', 'value': request.decision},
        traceId: trace,
      ),
    );
  }

  if (!scope.can(_capabilityFor(decision))) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final result = await services.platform.decide(
    operatorId: id,
    decision: decision,
    actorUserId: scope.actorUserId,
    // The scope's reason, not a body field. One place to read it is one place
    // that can forget to, and the middleware has already refused a mutation
    // without one.
    reason: scope.reason,
    detail: request.detail ?? request.reason,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      body: adminOperatorDto(value).toJson(),
      headers: {
        BelHeaders.traceId: trace,
        HttpHeaders.cacheControlHeader: 'private, no-store',
      },
    ),
    Err(:final DecisionRefusal failure) => switch (failure) {
      DecisionRefusal.unknownOperator => _error(
        HttpStatus.notFound,
        Problem.notFound(traceId: trace),
      ),
      DecisionRefusal.illegalTransition => _error(
        HttpStatus.conflict,
        ApiError(
          code: ErrorCode.conflict,
          params: {'decision': decision.name},
          traceId: trace,
        ),
      ),
    },
  };
}

/// Reviewing is not suspending, and offboarding is neither.
String _capabilityFor(OperatorDecision decision) => switch (decision) {
  OperatorDecision.approve ||
  OperatorDecision.activate ||
  OperatorDecision.requestInfo ||
  OperatorDecision.reject => Capability.operatorReview,
  OperatorDecision.suspend ||
  OperatorDecision.reinstate => Capability.operatorSuspend,
};

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
