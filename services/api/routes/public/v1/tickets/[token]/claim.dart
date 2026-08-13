import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/tickets/{token}/claim` — the booking becomes theirs
/// (ADR-0026).
///
/// The highest-value line in this feature, and the least visible: it is how a
/// walk-in at an agency counter becomes somebody with an account, without
/// anybody selling them anything.
///
/// The guichet already creates an account for every counter sale, from the
/// number the vendor types — so the booking has an owner and agency sales
/// reconcile against digital ones. That account is **unverified**: nobody has
/// ever proved they hold the number. This is where somebody does. They opened
/// the link, asked for a code at `step-up`, answered it at
/// `/public/v1/auth/sessions`, and arrive here holding an ordinary session.
///
/// Two rules, both in SQL rather than here:
///
///   * **Idempotent.** A second tap answers the same reference. A traveller
///     who claims from two devices is one person twice, not a conflict.
///   * **A booking held by a verified account is never re-pointed.** The
///     unverified account the counter made is what this is for; an account
///     somebody has actually signed in to belongs to a person, and a link is
///     not enough to take their booking away from them.
///
/// Answered with the reference so the app can go straight to the ticket, and
/// `403` when the claim is refused — which is a different answer from `404`
/// on purpose: the token was good, the booking was not available to take.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  // The one endpoint under `/tickets` that is not anonymous, and it has to be:
  // there is no account to hand the booking to until somebody has one.
  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final destination = await services.ticketLinks.destinationFor(token);
  if (destination == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final claimed = await services.ticketLinks.claim(
    token: token,
    userId: principal.userId,
  );

  if (claimed == null) {
    return Response.json(
      statusCode: HttpStatus.forbidden,
      body: Problem.forbidden(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: {'bookingRef': 'BEL-$claimed'},
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
