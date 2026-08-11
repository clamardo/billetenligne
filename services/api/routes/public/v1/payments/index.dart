import 'dart:io';

import 'package:bel_api/src/application/pay_for_booking.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/idempotency.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/payments` — push a prompt to a handset.
///
/// The narrowest point in the product after the hold, and the one where a
/// mistake takes somebody's money. Four things this handler does:
///
///   * **Requires an idempotency key.** A duplicate tap must not put two PIN
///     prompts on one handset, and on these networks the tap gets duplicated.
///   * **Sends no price.** The amount comes from the booking row inside the
///     transaction that opens the intent, so there is no window in which a
///     client could name what it owes.
///   * **Answers `pending`, not `paid`.** The traveller has not typed their
///     PIN yet. The app polls; the ticket is issued on `captured` and only
///     there.
///   * **Releases the idempotency claim when the rail refuses**, so "wrong
///     PIN" is retryable rather than "already answered" for a day.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
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

  final body = await context.request.json() as Map<String, Object?>;
  final request = StartPaymentRequest.fromJson(body);

  final idempotency = services.idempotencyFor(principal.userId);
  final outcome = await idempotency.check(
    key: context.request.headers[BelHeaders.idempotencyKey],
    scope: 'payments:${principal.userId}',
    body: body,
  );

  switch (outcome) {
    case ReplayStored(:final statusCode, :final body):
      return Response.json(
        statusCode: statusCode,
        body: body,
        headers: {BelHeaders.idempotencyReplayed: 'true'},
      );
    case MissingKey() || KeyReused() || StillInFlight():
      final error = Idempotency.errorFor(outcome, traceId: trace)!;
      return _error(Problem.statusFor(error.code), error, trace);
    case ProceedFresh(:final key):
      final account = await services.directory.byAuthUid(principal.authUid);

      final result = await services.payForBooking.start(
        bookingId: request.bookingId,
        userId: principal.userId,
        railId: request.railId,
        payerMsisdn: request.payerMsisdn,
        // Where the PSP sends them back to, on a checkout rail. Ignored by
        // every push rail.
        returnUrl: request.returnUrl,
        // Their own number, so the server can record whether they paid from
        // it. Recorded, never enforced.
        accountMsisdn: account?.phone,
        idempotencyKey: key,
        // Names which debt, never how much: the amount comes from the order's
        // own row inside the transaction that opens the intent.
        changeId: request.changeId,
      );

      return switch (result) {
        Ok(:final value) => await _accepted(idempotency, key, value, trace),
        Err(:final PaymentFailure failure) => await _fail(
          idempotency,
          key,
          failure,
          trace,
        ),
      };
  }
}

Future<Response> _accepted(
  Idempotency idempotency,
  String key,
  dynamic intent,
  String trace,
) async {
  final dto = _toDto(intent);
  await idempotency.record(key, HttpStatus.accepted, dto.toJson());

  return Response.json(
    statusCode: HttpStatus.accepted,
    body: dto.toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// A refusal is NOT stored as the answer to this key.
///
/// "Wrong PIN" is a fact about one attempt, not about this request. Storing it
/// would mean a traveller who retries with the right PIN gets the stale
/// refusal for a day.
Future<Response> _fail(
  Idempotency idempotency,
  String key,
  PaymentFailure failure,
  String trace,
) async {
  await idempotency.abandon(key);
  final error = Problem.fromFailure(failure, traceId: trace);
  return _error(Problem.statusFor(error.code), error, trace);
}

PaymentIntentDto _toDto(dynamic intent) => PaymentIntentDto(
  id: intent.id,
  state: (intent.state as PaymentState).name,
  railId: intent.railId,
  amount: intent.amount,
  createdAt: intent.createdAt,
  expiresAt: intent.expiresAt,
  failureCode: (intent.failureCode as PaymentFailureCode?)?.wire,
  // Where the traveller enters their card, on a checkout rail. Null on every
  // push rail, where the answer arrives on the handset and a browser opening
  // would be a screen nobody asked for.
  redirectUrl: intent.checkoutUrl as String?,
  // The app polls on a backoff. Told rather than guessed, so a rail that is
  // known to be slow today does not have every handset in the country asking
  // it every two seconds.
  pollAfterSeconds: 3,
);

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
