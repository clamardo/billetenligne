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

  final result = await services.signIn.start(
    request,
    language: language,
    source: _callerAddress(context),
  );

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

/// Who asked, as far as the network can say.
///
/// **The rightmost `X-Forwarded-For` entry, not the leftmost.** The header is
/// caller-controlled: a client can send `X-Forwarded-For: 1.2.3.4` and our
/// ingress will *append* the address it actually saw, so the leftmost entry is
/// whatever the caller felt like typing and the rightmost is the one hop we
/// trust. Taking the leftmost — which is the usual reading of "the client IP"
/// — would make this limit evadable with a header.
///
/// That reasoning holds for exactly one trusted proxy in front, which is what
/// we deploy. With more, the correct entry moves left by one per hop, and the
/// honest fix then is a configured hop count rather than a guess here.
///
/// Null when there is nothing to go on — a socket with no connection info, as
/// in a test. A null source is *not* bucketed with other nulls: lumping every
/// unknown caller into one bucket would let one of them exhaust the limit for
/// all of them.
String? _callerAddress(RequestContext context) {
  final forwarded = context.request.headers['x-forwarded-for'];
  if (forwarded != null && forwarded.trim().isNotEmpty) {
    final hops = forwarded
        .split(',')
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty);
    if (hops.isNotEmpty) return hops.last;
  }

  try {
    return context.request.connectionInfo.remoteAddress.address;
  } on Object {
    // `connectionInfo` is read out of the shelf context and throws when it is
    // absent, which is every test that builds a request by hand. Not having
    // an address is a real state, and it is not an error.
    return null;
  }
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
