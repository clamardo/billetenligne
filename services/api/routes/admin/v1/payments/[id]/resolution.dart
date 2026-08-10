import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

import '../index.dart' show unresolvedDto;

/// `POST /admin/v1/payments/{id}/resolution` — the queue's only exit.
///
/// Three outcomes:
///
///   * **`reask`** — put the question to the rail again. Most of these
///     resolve this way once the network has caught up, and offering it first
///     is what stops somebody guessing when they could have known;
///   * **`captured`** — the money did arrive. Settles for real, through the
///     same path a rail's own answer takes: ledger, this operator's
///     commission, ticket, outbox. A booking confirmed by an admin and one
///     confirmed by MTN are indistinguishable afterwards, because in the
///     ledger they are;
///   * **`failed`** — it did not. Terminal, with a failure code from the same
///     taxonomy the rails use, so the traveller's screen can say what
///     happened rather than "payment failed".
///
/// The actor and the reason are written to `payment_events` in every case.
/// That table is append-only and is the only thing that settles a dispute six
/// weeks later; "somebody marked it paid" is not an answer.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final scope = context.read<PlatformScope>();
  final services = context.read<Services>();

  if (!scope.can(Capability.paymentReconcile)) {
    return _error(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
  }

  final body = await context.request.json() as Map<String, Object?>;
  final request = ResolvePaymentRequest.fromJson(body);

  final existing = await services.platform.unresolvedPayment(
    id,
    actorUserId: scope.actorUserId,
  );
  if (existing == null) {
    return _error(HttpStatus.notFound, Problem.notFound(traceId: trace));
  }

  switch (request.outcome) {
    case 'reask':
      await services.payForBooking.reconcile(
        intentId: id,
        railId: existing.railId,
        railTransactionId: existing.railTransactionId,
        // The schema's vocabulary: callback · poll · manual · reconciliation.
        // Asking the rail again on a human's instruction is the fourth one.
        source: 'reconciliation',
      );
    case 'captured':
      await services.payForBooking.resolve(
        intentId: id,
        to: PaymentState.captured,
        actorUserId: scope.actorUserId,
        reason: '${scope.reason} — ${request.reason}',
      );
    case 'failed':
      await services.payForBooking.resolve(
        intentId: id,
        to: PaymentState.failed,
        actorUserId: scope.actorUserId,
        reason: '${scope.reason} — ${request.reason}',
        failureCode: _codeFor(request.failureCode),
      );
    default:
      return _error(
        HttpStatus.badRequest,
        ApiError(
          code: ErrorCode.badRequest,
          params: {'field': 'outcome', 'value': request.outcome},
          traceId: trace,
        ),
      );
  }

  await services.platform.recordRead(
    actorUserId: scope.actorUserId,
    reason: '${scope.reason} — ${request.reason}',
    action: 'payment.resolve.${request.outcome}',
    subjectType: 'payment_intent',
    subjectId: id,
    operatorId: existing.operatorId,
    traceId: trace,
  );

  // Re-read rather than reporting what we asked for. A `reask` that changed
  // nothing must not come back looking like a resolution.
  final now = await services.platform.unresolvedPayment(
    id,
    actorUserId: scope.actorUserId,
  );

  return Response.json(
    body: (now == null ? unresolvedDto(existing) : unresolvedDto(now)).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// Falls back to the honest one. `timeout_no_response` is what an unanswered
/// prompt actually was, and inventing `insufficient_funds` would put a
/// sentence on a traveller's screen that nobody can support.
PaymentFailureCode _codeFor(String? wire) {
  if (wire == null) return PaymentFailureCode.timeoutNoResponse;
  for (final code in PaymentFailureCode.values) {
    if (code.wire == wire || code.name == wire) return code;
  }
  return PaymentFailureCode.timeoutNoResponse;
}

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
