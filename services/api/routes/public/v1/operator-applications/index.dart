import 'dart:io';

import 'package:bel_api/src/application/ports/operator_applications.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `/public/v1/operator-applications` — self-signup (§2.1, §2.2).
///
/// **On the public surface, and that is the whole design.** An applicant
/// holds an ordinary traveller session — the same emailed one-time code a
/// passenger signs in with — and belongs to no tenant, because the tenant is
/// what they are asking us to create. The console's middleware would refuse
/// them before a handler ran, so this lives here, under a role whose grant on
/// `operators` is one INSERT pinned to `application_draft` and an UPDATE on
/// four columns (migration 0015).
///
///   GET    — whatever this account is applying with, or 404
///   POST   — start one, from a company name and nothing else
///   PUT    — save the whole record; the wizard calls this constantly
///
/// PUT rather than PATCH, and the whole record rather than the changed
/// field: "save on every field" over a connection that drops is a stream of
/// partial writes, and a full replace makes the last one win instead of
/// making the order matter.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final principal = context.read<Principal>();

  if (principal.isAnonymous) {
    return _json(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace));
  }

  final services = context.read<Services>();
  final account = await services.directory.byAuthUid(principal.authUid);
  if (account == null) {
    return _json(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace));
  }

  final applications = services.applications;

  return switch (context.request.method) {
    HttpMethod.get => _mine(applications, account.id, trace),
    HttpMethod.post => _start(context, applications, account.id, trace),
    HttpMethod.put => _save(context, applications, account.id, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _mine(
  OperatorApplications applications,
  String userId,
  String trace,
) async {
  final mine = await applications.mine(userId: userId);
  if (mine == null) {
    return _json(HttpStatus.notFound, Problem.notFound(traceId: trace));
  }
  return _ok(mine, trace);
}

Future<Response> _start(
  RequestContext context,
  OperatorApplications applications,
  String userId,
  String trace,
) async {
  final body = await context.request.json() as Map<String, Object?>;
  final legalName = (body['legalName'] as String? ?? '').trim();

  // Two characters is not a company. Checked here rather than only in the
  // domain because this one field decides the operator code, and a code
  // derived from an empty string is a permanent artefact of a moment's
  // impatience.
  if (legalName.length < 3) {
    return _json(
      HttpStatus.badRequest,
      ApiError(
        code: ErrorCode.badRequest,
        params: {'field': 'legalName'},
        traceId: trace,
      ),
    );
  }

  final started = await applications.start(
    userId: userId,
    legalName: legalName,
    marketCode: context.read<Services>().market.code,
  );

  return started.fold(
    (application) => _ok(application, trace, status: HttpStatus.created),
    (refusal) => _refused(refusal, trace),
  );
}

Future<Response> _save(
  RequestContext context,
  OperatorApplications applications,
  String userId,
  String trace,
) async {
  final body = await context.request.json() as Map<String, Object?>;
  final facts = ApplicationFactsDto.fromJson(body).facts;

  final saved = await applications.save(userId: userId, facts: facts);

  return saved.fold(
    (application) => _ok(application, trace),
    (refusal) => _refused(refusal, trace),
  );
}

Response _ok(
  OperatorApplication application,
  String trace, {
  int status = HttpStatus.ok,
}) => Response.json(
  statusCode: status,
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
);

/// Refusals map to 409 rather than 400 throughout: none of them is a
/// malformed request. Every one is a true statement about the application's
/// current state, which is exactly what a conflict is.
Response _refused(ApplicationRefusal refusal, String trace) => _json(
  refusal == ApplicationRefusal.noApplication
      ? HttpStatus.notFound
      : HttpStatus.conflict,
  ApiError(code: applicationErrorCode(refusal), traceId: trace),
);

String applicationErrorCode(ApplicationRefusal refusal) => switch (refusal) {
  ApplicationRefusal.alreadyApplied => ErrorCode.applicationAlreadyExists,
  ApplicationRefusal.noApplication => ErrorCode.applicationNotFound,
  ApplicationRefusal.locked => ErrorCode.applicationLocked,
  ApplicationRefusal.incomplete => ErrorCode.applicationIncomplete,
};

Response _json(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
