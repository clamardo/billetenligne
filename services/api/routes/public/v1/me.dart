import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/me` — the signed-in traveller's own profile.
///
/// Exists for one reason beyond rendering a name: it is how the app finds out
/// that a token it still holds is no longer good. A refresh token survives a
/// disabled account, so "I have a token" and "I am still a customer" are
/// different claims, and only the server can settle the second.
///
/// Carries no roles and no capabilities. What a caller may do is decided
/// server-side on every request (ADR-0018); a field here that the UI treated
/// as authority would be a claim the client could edit.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();

  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final account = await context.read<Services>().directory.byAuthUid(
    principal.authUid,
  );

  // Authenticated a moment ago in the middleware, gone now. Rare, and the
  // honest answer is the same 401 — the account was disabled or deleted
  // between the two reads.
  if (account == null) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    body: AccountDto(
      id: account.id,
      language: account.language,
      email: account.email,
      phone: account.phone,
      fullName: account.fullName,
    ).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}
