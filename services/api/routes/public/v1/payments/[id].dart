import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/payments/{id}` — has it settled?
///
/// The waiting screen's endpoint. It **re-queries the rail** on every call
/// rather than reading our own row, and that is the point: a callback can be
/// lost, and a traveller staring at a spinner while the money has already left
/// their wallet is the single worst state this product can be in.
///
/// The poll is bounded by the intent's own window, so a handset that never
/// answers stops being asked about — and the worker keeps asking after the
/// app has gone to sleep.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  if (principal.isAnonymous) {
    return _error(
      HttpStatus.unauthorized,
      Problem.unauthorized(traceId: trace),
      trace,
    );
  }

  final own = await services.payments.byId(
    intentId: id,
    userId: principal.userId,
  );

  // Not theirs, or not an intent. One answer: telling a stranger which would
  // confirm the id exists.
  if (own == null) {
    return _error(HttpStatus.notFound, Problem.notFound(traceId: trace), trace);
  }

  // Terminal already — no rail call. Asking a PSP about a settled transaction
  // on every poll is how a rate limit gets hit on the happy path.
  final intent = own.state.isTerminal
      ? own
      : await services.payForBooking.reconcile(
              intentId: own.id,
              railId: own.railId,
              railTransactionId: own.railTransactionId,
            ) ??
            own;

  return Response.json(
    body: PaymentIntentDto(
      id: intent.id,
      state: intent.state.name,
      railId: intent.railId,
      amount: intent.amount,
      createdAt: intent.createdAt,
      expiresAt: intent.expiresAt,
      failureCode: intent.failureCode?.wire,
      // The page again, on a checkout rail. Answered on every poll and not
      // only on the first: the app may have been killed while somebody was
      // typing a card number into a browser, and the screen they come back
      // to has to be able to offer the same page rather than mint a second
      // transaction at the PSP.
      redirectUrl: intent.checkoutUrl,
      // Backs off as the wait grows: 5 s, then 10 s past a minute. A handset
      // polling every three seconds for ten minutes is 200 requests and a
      // meaningful slice of a prepaid bundle.
      pollAfterSeconds: intent.state.isTerminal
          ? null
          : (DateTime.now().toUtc().difference(intent.createdAt).inSeconds > 60
                ? 10
                : 5),
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
