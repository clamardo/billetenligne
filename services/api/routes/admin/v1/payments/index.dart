import 'dart:io';

import 'package:bel_api/src/application/ports/platform_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/payments` — the reconciliation queue (ADR-0005).
///
/// The screen this product needs before launch rather than after its first
/// incident. Every row here is money in limbo and a customer in the dark, so
/// it is a work queue and not a report: longest-waiting first, everything
/// needed to decide in the row, and a way to reach the person waiting.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  if (!scope.can(Capability.paymentReconcile)) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final queue = await services.platform.unresolvedPayments(
    actorUserId: scope.actorUserId,
  );

  await services.platform.recordRead(
    actorUserId: scope.actorUserId,
    reason: scope.reason,
    action: 'payment.queue',
    subjectType: 'payment_queue',
    subjectId: '${queue.length}',
    traceId: trace,
  );

  return Response.json(
    body: {'items': [for (final p in queue) unresolvedDto(p).toJson()]},
    headers: {
      BelHeaders.traceId: trace,
      // Phone numbers, amounts and booking references, across every tenant.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

UnresolvedPaymentDto unresolvedDto(UnresolvedPayment p) => UnresolvedPaymentDto(
  intentId: p.intentId,
  state: p.state,
  railId: p.railId,
  amount: p.amount,
  payerMsisdn: p.payerMsisdn,
  createdAt: p.createdAt,
  bookingId: p.bookingId,
  bookingRef: p.bookingRef,
  bookingState: p.bookingState,
  operatorId: p.operatorId,
  operatorName: p.operatorName,
  pollAttempts: p.pollAttempts,
  lastPolledAt: p.lastPolledAt,
  railTransactionId: p.railTransactionId,
  travellerPhone: p.travellerPhone,
  travellerEmail: p.travellerEmail,
  departsAt: p.departsAt,
  originCity: p.originCity,
  destinationCity: p.destinationCity,
);

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
