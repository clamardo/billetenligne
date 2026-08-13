import 'dart:io';

import 'package:bel_api/src/application/sign_in.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/tickets/{token}/step-up` — "prove it is you" (ADR-0026).
///
/// The token is the credential for **seeing** a ticket and deliberately for
/// nothing else. Cancelling, refunding or moving a seat is a different act,
/// and it takes a one-time code.
///
/// **The caller supplies no address.** The code goes to the one stored on the
/// link at mint time, and there is no field here that could change that: an
/// endpoint that took a destination would be an open relay with our domain on
/// it, and a traveller who later changes their email must not find that an old
/// link now sends codes somewhere new.
///
/// **It is sign-in, not a second auth system.** The challenge, the cooldown,
/// the five-attempt cap and the per-host limit are the ones ADR-0013 already
/// specifies, and the code is answered at
/// `POST /public/v1/auth/sessions` like any other. Which means the traveller
/// ends this flow holding an ordinary session — and that is what makes the
/// claim below possible at all.
///
/// A revoked link, an expired one and a token nobody issued are one 404, as
/// everywhere else on this surface.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final destination = await services.ticketLinks.destinationFor(token);
  if (destination == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  // A market that cannot send on this channel says so, rather than leaving
  // somebody on a screen waiting for a message that is never coming. The same
  // refusal `/auth/challenges` gives, for the same reason.
  if (destination.channel == 'phone' && !services.smsConfigured) {
    return Response.json(
      statusCode: HttpStatus.serviceUnavailable,
      body: ApiError(code: ErrorCode.unavailable, traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final language = context.request.headers[BelHeaders.language] ?? 'fr';
  final result = await services.signIn.start(
    destination.channel == 'phone'
        ? StartSignInRequest.phone(destination.sentTo)
        : StartSignInRequest.email(destination.sentTo),
    language: language,
    source: _callerAddress(context),
  );

  return switch (result) {
    Ok(:final value) => Response.json(
      statusCode: HttpStatus.accepted,
      // Masked, like every other challenge: the holder of the link already
      // knows where it went, and printing it in full turns a stolen link into
      // a stolen address.
      body: value.toJson(),
      headers: {
        BelHeaders.traceId: trace,
        HttpHeaders.cacheControlHeader: 'private, no-store',
      },
    ),
    Err(:final SignInFailure failure) => Response.json(
      statusCode: Problem.statusFor(failure.code),
      body: Problem.fromFailure(failure, traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    ),
  };
}

/// The host, for the per-source limit. Behind a proxy the socket is the
/// proxy, so the forwarded chain's first hop is the caller when there is one.
String? _callerAddress(RequestContext context) {
  final forwarded = context.request.headers['x-forwarded-for'];
  if (forwarded != null && forwarded.isNotEmpty) {
    return forwarded.split(',').first.trim();
  }
  return context.request.connectionInfo.remoteAddress.address;
}
