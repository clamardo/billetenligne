import 'dart:io';

import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /admin/v1/operators/{id}/payment_accounts/{accountId}/decision` —
/// verify · reject.
///
/// This is the only thing in this deployment that writes `verified_at` on
/// `operator_payment_accounts` — the operator's own console can add a number,
/// never confirm it (`operator_console.dart`'s `savePaymentAccount` doc-
/// comment). Two mistakes it refuses, mirroring the operator-decision route
/// beside it:
///
///   * **an unknown decision name** — 400, not a silent no-op;
///   * **an account already decided, or one that belongs to a different
///     operator than the id in the path** — 409/404. The guard is in SQL
///     too, so two reviewers verifying the same account at once produce one
///     verification.
Future<Response> onRequest(
  RequestContext context,
  String id,
  String accountId,
) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  if (!scope.can(Capability.paymentAccountVerify)) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final body = await context.request.json() as Map<String, Object?>;
  final request = PaymentAccountDecisionRequest.fromJson(body);

  final decision = PaymentAccountDecision.byName(request.decision);
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

  final result = await services.platform.decidePaymentAccount(
    operatorId: id,
    accountId: accountId,
    decision: decision,
    actorUserId: scope.actorUserId,
    reason: scope.reason,
    detail: request.detail,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      body: PaymentAccountDto(
        id: value.id,
        railId: value.railId,
        msisdn: value.msisdn,
        displayName: value.displayName,
        verified: value.verified,
        active: value.active,
      ).toJson(),
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
      // The two activation preconditions (J2) share the enum and cannot reach
      // here: verifying an account is not a lifecycle transition. Folded into
      // the same conflict rather than left as a wildcard, so the next value
      // added to `DecisionRefusal` still breaks this switch and gets read.
      DecisionRefusal.illegalTransition ||
      DecisionRefusal.needsVerifiedAccount ||
      DecisionRefusal.needsAgreement => _error(
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

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
