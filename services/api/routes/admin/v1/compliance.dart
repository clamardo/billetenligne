import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/compliance` — the expiry calendar across every operator.
///
/// The **Conformité** screen of §6, and the queue item the T−7 rung of the
/// ladder is supposed to raise. `?days=90` widens the window; the default is
/// sixty, which is where the first reminder goes out.
///
/// Already-lapsed documents are included and sorted to the top. A calendar
/// that only looked forward would drop an operator off the screen at the
/// exact moment they became the reason somebody has to make a phone call.
///
/// Audited like every cross-tenant read (ADR-0011): the fact of the read,
/// with the actor and their stated reason — not one row per operator, which
/// would drown the trail that matters.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  // The same authority that reviews an application. Compliance is the same
  // job on a slower clock.
  if (!scope.can(Capability.operatorReview)) {
    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(traceId: trace).toJson(),
    );
  }

  final days =
      int.tryParse(
        context.request.uri.queryParameters['days'] ?? '',
      )?.clamp(1, 365) ??
      60;

  final items = await services.compliance.calendar(
    actorUserId: scope.actorUserId,
    withinDays: days,
  );

  await services.platform.recordRead(
    actorUserId: scope.actorUserId,
    reason: scope.reason,
    action: 'compliance.list',
    subjectType: 'compliance_calendar',
    subjectId: '$days',
    traceId: trace,
  );

  return Response.json(
    body: {
      'items': [for (final c in items) c.toJson()],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
