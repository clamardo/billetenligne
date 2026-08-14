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
/// `PATCH /public/v1/me` — the one thing about themselves they can change.
///
/// **Which is the language, and it had nowhere to be written.** `language` was
/// stamped when the account was created, from whatever locale the handset was
/// in, and never updated — so somebody whose first sign-in happened on a phone
/// set to English received French forever. The stored value is what the server
/// renders every e-mail and every SMS in (ADR-0019 rule 3), and it is the only
/// copy that survives the app being closed, which is why a switch in the app
/// has to reach it rather than only repainting the screen.
///
/// Carries no roles and no capabilities. What a caller may do is decided
/// server-side on every request (ADR-0018); a field here that the UI treated
/// as authority would be a claim the client could edit.
Future<Response> onRequest(RequestContext context) async {
  final method = context.request.method;
  if (method != HttpMethod.get && method != HttpMethod.patch) {
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

  final services = context.read<Services>();
  final account = await services.directory.byAuthUid(principal.authUid);

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

  var language = account.language;

  if (method == HttpMethod.patch) {
    final body = await context.request.json();
    final requested = (body is Map ? body['language'] : null) as String?;

    // A language this deployment does not carry a catalog for would be stored
    // happily and then fall back to French on every message ever sent — which
    // reads as a bug in the catalog rather than as a rejected value.
    if (requested == null || !services.market.languages.contains(requested)) {
      return _error(
        HttpStatus.badRequest,
        ApiError(
          code: ErrorCode.badRequest,
          params: const {'field': 'language'},
          traceId: trace,
        ),
        trace,
      );
    }

    if (requested != language) {
      final saved = await services.directory.setLanguage(
        userId: account.id,
        language: requested,
      );
      // The account went away between the read above and this write. Same
      // answer as any other vanished account.
      if (!saved) {
        return _error(
          HttpStatus.unauthorized,
          Problem.unauthorized(traceId: trace),
          trace,
        );
      }
      language = requested;
    }
  }

  return Response.json(
    body: AccountDto(
      id: account.id,
      language: language,
      email: account.email,
      phone: account.phone,
      fullName: account.fullName,
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      // Never cached: it is one person's own row, and the whole point of the
      // PATCH is that the answer changed.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
