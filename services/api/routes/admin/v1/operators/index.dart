import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import '[id]/index.dart' show adminOperatorDto;

/// `GET /admin/v1/operators` — the review queue and the roster.
///
/// `?status=registered,under_review` narrows it; no filter means everybody.
/// Oldest first, always, because a queue worked newest-first is a queue with
/// a permanently abandoned tail — and the SLA this team publishes (90% of
/// complete applications decided within 48 hours) is a promise about the
/// tail, not about the average.
///
/// The read itself is audited. Not the rows returned — an audit row per
/// operator per refresh would drown the trail that matters — but the fact
/// that this person listed operators, with their stated reason.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  if (!scope.can(Capability.operatorReview)) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final raw = context.request.uri.queryParameters['status'];
  final statuses = <String>{
    for (final s in (raw ?? '').split(',')) if (s.trim().isNotEmpty) s.trim(),
  };

  final operators = await services.platform.operators(
    actorUserId: scope.actorUserId,
    statuses: statuses,
  );

  await services.platform.recordRead(
    actorUserId: scope.actorUserId,
    reason: scope.reason,
    action: 'operator.list',
    subjectType: 'operator_queue',
    subjectId: statuses.isEmpty ? 'all' : statuses.join(','),
    traceId: trace,
  );

  return Response.json(
    body: {
      'items': [for (final o in operators) adminOperatorDto(o).toJson()],
    },
    headers: {
      BelHeaders.traceId: trace,
      // Legal names, tax ids and commission rates. A shared cache holding any
      // of them is a shared cache leaking all three.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
