import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `PUT /console/v1/policies/default` — which version future sales carry.
///
/// A separate route rather than a flag on the policy body, because setting a
/// default and writing a policy are different acts with different blast
/// radii. Writing one changes nothing that is already sold; pointing the
/// default at it changes every sale from this second onward. Folding them
/// together would mean saving a draft could silently start selling under it.
///
/// **Only future bookings.** Bookings already made keep the version stamped
/// on them, which is the point of versioning (ADR-0015 rule 1) — and rule 2
/// says the console states that before the operator confirms, which it does.
///
/// A null `policyId` clears the default. That is how an operator stops
/// offering refunds through us entirely, and it is a legitimate answer: no
/// policy means no self-service refund, not a hidden one.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  if (context.request.method != HttpMethod.put) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.policyManage);
  if (denied != null) return denied;

  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  final body = await context.request.json() as Map<String, Object?>;
  final policyId = body['policyId'];
  final version = body['version'];

  if (policyId != null && policyId is! String) {
    return _badRequest(trace, 'policyId');
  }
  // Both or neither. A policy id without a version names a policy rather than
  // the terms, and "the policy" is exactly what a booking must not be judged
  // by two years from now.
  if ((policyId == null) != (version == null)) {
    return _badRequest(trace, 'version');
  }
  if (version != null && (version is! int || version < 1)) {
    return _badRequest(trace, 'version');
  }

  final saved = await console.setDefaultRefundPolicy(
    operatorId: scope.operatorId,
    policyId: policyId as String?,
    version: version as int?,
  );

  // Clearing succeeds by returning nothing, which is also what naming a
  // policy that is not this operator's does — RLS made it invisible, and
  // answering "no such policy" is how a tenant learns nothing about another
  // tenant's ids.
  if (saved == null) {
    if (policyId == null) {
      return Response(
        statusCode: HttpStatus.noContent,
        headers: {BelHeaders.traceId: trace},
      );
    }
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: RefundPolicyDto.fromDomain(
      saved.policy,
      name: saved.name,
      isDefault: true,
      bookingCount: saved.bookingCount,
    ).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
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
