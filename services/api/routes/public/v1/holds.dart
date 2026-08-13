import 'dart:io';

import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/idempotency.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/holds` — claim seats.
///
/// The narrowest point in the entire funnel. Everything before it is browsing;
/// everything after it is money.
///
/// Three things this handler does that are easy to leave out and expensive to
/// add back:
///
///   * **Requires an idempotency key.** A duplicate tap on a dropped
///     connection must not produce two holds on two different seats, and in
///     Congo the connection drops.
///   * **Requires a signed-in traveller.** Not because browsing needs an
///     account — it deliberately does not (ADR-0013) — but because a hold has
///     an owner, and an anonymous hold is one nobody can be told about when it
///     is about to expire.
///   * **Releases the idempotency claim when the work fails.** Otherwise a
///     seat that was genuinely unavailable at 06:00:01 stays "already
///     answered" for 24 hours, and the traveller can never retry the request
///     that would now succeed.
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
  final request = CreateHoldRequest.fromJson(body);

  final idempotency = services.idempotencyFor(principal.userId);
  final outcome = await idempotency.check(
    key: context.request.headers[BelHeaders.idempotencyKey],
    scope: 'holds:${principal.userId}',
    body: body,
  );

  switch (outcome) {
    case ReplayStored(:final statusCode, :final body):
      // Byte-identical to the first answer, plus a header saying so. That
      // header is what lets support distinguish "held twice" from "asked
      // twice, held once" without reading a log.
      return Response.json(
        statusCode: statusCode,
        body: body,
        headers: {BelHeaders.idempotencyReplayed: 'true'},
      );
    case MissingKey() || KeyReused() || StillInFlight():
      final error = Idempotency.errorFor(outcome, traceId: trace)!;
      return _error(Problem.statusFor(error.code), error, trace);
    // Nothing has happened under this key yet. Do the work.
    case ProceedFresh(:final key):
      return _hold(services, idempotency, key, request, principal, trace);
  }
}

Future<Response> _hold(
  Services services,
  Idempotency idempotency,
  String key,
  CreateHoldRequest request,
  Principal principal,
  String trace,
) async {
  final result = await services.holdSeats(
    departureId: request.departureId,
    seatLabels: request.seatLabels,
    userId: principal.userId,
    idempotencyKey: key,
    // Both or neither, and a half-named pair is refused rather than quietly
    // widened to the whole journey — which would charge a traveller the
    // through fare for a leg (ADR-0025).
    fromCity: request.toCity == null ? null : request.fromCity,
    toCity: request.fromCity == null ? null : request.toCity,
  );

  return switch (result) {
    Ok(:final value) => await _complete(
      idempotency,
      key,
      HttpStatus.created,
      value.toJson(),
      trace,
    ),
    Err(:final HoldSeatsFailure failure) => await _fail(
      idempotency,
      key,
      failure,
      trace,
    ),
  };
}

Future<Response> _complete(
  Idempotency idempotency,
  String key,
  int status,
  Map<String, Object?> body,
  String trace,
) async {
  await idempotency.record(key, status, body);
  return Response.json(
    statusCode: status,
    body: body,
    headers: {BelHeaders.traceId: trace},
  );
}

/// A refusal is NOT stored as the answer to this key.
///
/// "Seat taken" is a fact about the world at one instant, not about this
/// request. Storing it would mean a traveller who retries thirty seconds after
/// somebody else's hold lapses gets the stale refusal instead of the seat, and
/// no amount of retrying would ever fix it.
Future<Response> _fail(
  Idempotency idempotency,
  String key,
  HoldSeatsFailure failure,
  String trace,
) async {
  await idempotency.abandon(key);
  final error = Problem.fromFailure(failure, traceId: trace);
  return _error(Problem.statusFor(error.code), error, trace);
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
