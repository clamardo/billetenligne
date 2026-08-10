import 'dart:io';

import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/operators/{id}` — everything about one operator, on one
/// page.
///
/// Documents, the agreement, the counts and the audit trail together, because
/// tab-hunting during a review is how a missing insurance certificate gets
/// approved (`03-operator-lifecycle.md` §6).
///
/// **This read is audited with the subject.** Opening one operator's file is
/// exactly the cross-tenant act ADR-0011 asks to be attributable — "who
/// looked at Ocean du Nord's revenue, and why" is a question that gets asked
/// after the fact, and only a row written now can answer it.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  if (!scope.can(Capability.operatorReview)) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final detail = await services.platform.operatorDetail(
    id,
    actorUserId: scope.actorUserId,
  );

  if (detail == null) {
    return _error(HttpStatus.notFound, Problem.notFound(traceId: trace));
  }

  await services.platform.recordRead(
    actorUserId: scope.actorUserId,
    reason: scope.reason,
    action: 'operator.read',
    subjectType: 'operator',
    subjectId: id,
    operatorId: id,
    traceId: trace,
  );

  return Response.json(
    body: AdminOperatorDetailDto(
      operator: adminOperatorDto(detail.summary),
      documents: [
        for (final d in detail.documents)
          KybDocumentDto(
            id: d.id,
            docType: d.docType,
            createdAt: d.createdAt,
            expiresAt: d.expiresAt,
            verifiedAt: d.verifiedAt,
            rejectedReason: d.rejectedReason,
          ),
      ],
      // The storage key never leaves the server. Fetching a scan is its own
      // request answered with a short-lived signed URL, so a leaked JSON
      // response is not a leaked passport photograph.
      trail: [
        for (final e in detail.trail)
          AuditEntryDto(
            action: e.action,
            actorType: e.actorType,
            actorId: e.actorId,
            reason: e.reason,
            createdAt: e.createdAt,
          ),
      ],
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// Shared with the queue route, so one operator cannot be described two ways.
AdminOperatorDto adminOperatorDto(OperatorSummary o) => AdminOperatorDto(
  id: o.id,
  code: o.code,
  legalName: o.legalName,
  tradingName: o.tradingName,
  status: o.status,
  marketCode: o.marketCode,
  createdAt: o.createdAt,
  commissionBps: o.commission.bps,
  rccmNumber: o.rccmNumber,
  taxId: o.taxId,
  documentCount: o.documentCount,
  expiringDocumentCount: o.expiringDocumentCount,
  vehicleCount: o.vehicleCount,
  routeCount: o.routeCount,
  staffCount: o.staffCount,
);

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
