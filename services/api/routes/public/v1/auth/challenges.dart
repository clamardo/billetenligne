import 'dart:io';

import 'package:bel_api/src/application/sign_in.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/auth/challenges` — "send me a code".
///
/// Open to anonymous callers, necessarily: this is how somebody stops being
/// anonymous. Three properties make that safe to expose:
///
///   * **The answer is the same for a stranger and a returning customer.**
///     Sign-up and sign-in are one flow, so there is nothing here that could
///     confirm whether an address is registered — which is what an
///     enumeration attack is looking for.
///   * **The cooldown is server-side and keyed on the address.** A client
///     rendering its own countdown is a suggestion; this is the limit. It is
///     the cost control as much as the security control — every resend is a
///     message we pay for (ADR-0019).
///   * **The response never carries the code.** Obvious, and worth the line:
///     the one place it is easy to leak is a debug field nobody removed.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final request = StartSignInRequest.fromJson(body);

  // SMS is not configured yet (ADR-0019) and pretending otherwise would send a
  // traveller to a screen waiting for a message that is never coming. Refused
  // here rather than in the use case, because the use case is genuinely
  // channel-agnostic and this is a fact about today's deployment.
  if (request.channel == SignInChannel.phone && !services.smsConfigured) {
    return _error(
      HttpStatus.serviceUnavailable,
      ApiError(code: ErrorCode.unavailable, traceId: trace),
      trace,
    );
  }

  final language = context.request.headers[BelHeaders.language] ?? 'fr';

  final result = await services.signIn.start(request, language: language);

  return switch (result) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.accepted,
      body: value.toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
    Err(:final SignInFailure failure) => _error(
      Problem.statusFor(failure.code),
      Problem.fromFailure(failure, traceId: trace),
      trace,
    ),
  };
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
