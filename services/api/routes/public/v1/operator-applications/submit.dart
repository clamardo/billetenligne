import 'dart:io';

import 'package:bel_api/src/application/ports/operator_applications.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart' show applicationErrorCode;

/// `POST /public/v1/operator-applications/submit` — hand it to the queue.
///
/// Its own route rather than a `submitted: true` field on the save above, for
/// the same reason the console's refund policy default is its own route:
/// saving changes nothing anybody else sees, and submitting puts a row in
/// front of a reviewer with a 48-hour published promise attached to it. One
/// of those is safe to call on every keystroke and the other is not.
///
/// The completeness check runs here too, against the server's own clock, so
/// an insurance certificate that expired between filling the form and
/// pressing send is caught by us rather than by a reviewer.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();

  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final principal = context.read<Principal>();
  if (principal.isAnonymous) {
    return _json(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace));
  }

  final services = context.read<Services>();
  final account = await services.directory.byAuthUid(principal.authUid);
  if (account == null) {
    return _json(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace));
  }

  final submitted = await services.applications.submit(
    userId: account.id,
    asOf: services.clock.now(),
  );

  return submitted.fold(
    (application) => Response.json(
      body: OperatorApplicationDto(
        operatorId: application.operatorId,
        code: application.code,
        status: application.status,
        facts: application.facts,
        createdAt: application.createdAt,
        submittedAt: application.submittedAt,
        decisionReason: application.decisionReason,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    (refusal) => _json(
      refusal == ApplicationRefusal.noApplication
          ? HttpStatus.notFound
          : HttpStatus.conflict,
      ApiError(code: applicationErrorCode(refusal), traceId: trace),
    ),
  );
}

Response _json(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
