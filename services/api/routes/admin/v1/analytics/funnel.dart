import 'dart:io';

import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/analytics/funnel` — where people leave (`04-payments.md` §8).
///
/// Derived entirely from rows that already exist for their own reasons: a
/// hold, the booking that quotes it, the intents against that booking. There
/// is no events table and no tracker, which means the funnel cannot drift
/// from the sales — the number of tickets on this screen is the number of
/// tickets in the ledger, because it is counted from the same rows.
///
/// Gated on `finance.read`, the one capability every platform role holds
/// including `viewer`: nothing here names a traveller, an operator's daily
/// takings or a phone number. It is still an audited read — it crosses every
/// tenant, and `11-security.md` asks that crossing to leave a trace whether
/// or not the thing read was personal.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  if (!scope.can(Capability.financeRead)) {
    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(traceId: trace).toJson(),
    );
  }

  final query = context.request.uri.queryParameters;
  final days = int.tryParse(query['days'] ?? '') ?? 14;
  final operatorId = query['operatorId'];
  final channel = query['channel'] ?? 'app';

  final rows = await services.platform.funnel(
    actorUserId: scope.actorUserId,
    days: days,
    operatorId: operatorId,
    channel: channel,
  );

  await services.platform.recordRead(
    actorUserId: scope.actorUserId,
    reason: scope.reason,
    action: 'analytics.funnel',
    subjectType: 'funnel',
    subjectId: '$channel/${rows.length}d',
    operatorId: operatorId,
    traceId: trace,
  );

  final dto = FunnelDto(
    days: [for (final d in rows) _day(d)],
    channel: channel,
    operatorId: operatorId,
  );

  return Response.json(
    body: dto.toJson(),
    headers: {
      BelHeaders.traceId: trace,
      // Aggregate, but cross-tenant and current. A proxy holding yesterday's
      // funnel is a proxy answering "is the rail broken?" with "it was fine".
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// The date, formatted once, here.
///
/// `toIso8601String().substring(0, 10)` would take whatever the driver
/// handed back — and a `date` column arrives as local midnight, so a UTC
/// conversion on the way out can move it a day. The parts are read directly.
FunnelDayDto _day(FunnelDay d) => FunnelDayDto(
  day:
      '${d.day.year.toString().padLeft(4, '0')}-'
      '${d.day.month.toString().padLeft(2, '0')}-'
      '${d.day.day.toString().padLeft(2, '0')}',
  held: d.held,
  reserved: d.reserved,
  paid: d.paid,
  holdsLapsed: d.holdsLapsed,
  paymentsFailed: d.paymentsFailed,
);
