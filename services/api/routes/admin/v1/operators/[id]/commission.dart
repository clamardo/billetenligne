import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart' show adminOperatorDto;

/// `PUT /admin/v1/operators/{id}/commission` — what this operator negotiated.
///
/// Its own route rather than a field on the decision, because changing the
/// rate of an operator who is already selling is a different act from
/// approving an application — and it is the number they will argue about six
/// months later, so it is audited with the old rate and the new one in one
/// row.
///
/// Basis points on the wire. A percentage that arrives as `0.075` is a
/// percentage somebody eventually sends as `7.5`, and the difference is a
/// hundredfold error in what we take from a fare.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.put) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  // Deliberately the strictest capability in the file. A commission is the
  // platform's side of a signed agreement, and `operations` reviewing an
  // application is not the same authority as changing what we charge.
  if (!scope.can(Capability.operatorOffboard)) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final body = await context.request.json() as Map<String, Object?>;
  final request = SetCommissionRequest.fromJson(body);

  final CommissionTerm term;
  try {
    term = CommissionTerm(request.commissionBps);
  } on ArgumentError {
    // The domain's ceiling is the schema's ceiling. A rate the database would
    // refuse must never reach a ledger posting, and saying which field was
    // wrong is cheaper than a 500 from a CHECK constraint.
    return _error(
      HttpStatus.badRequest,
      ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'commissionBps', 'max': CommissionTerm.maxBps},
        traceId: trace,
      ),
    );
  }

  final result = await services.platform.setCommission(
    operatorId: id,
    term: term,
    actorUserId: scope.actorUserId,
    reason: scope.reason,
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      body: adminOperatorDto(value).toJson(),
      headers: {
        BelHeaders.traceId: trace,
        HttpHeaders.cacheControlHeader: 'private, no-store',
      },
    ),
    Err() => _error(HttpStatus.notFound, Problem.notFound(traceId: trace)),
  };
}

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
