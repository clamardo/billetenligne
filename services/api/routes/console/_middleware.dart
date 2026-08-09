import 'dart:io';

import 'package:bel_api/src/adapters/unavailable_operator_console.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// The operator surface.
///
/// Authorisation lives here rather than in the root middleware, deliberately
/// (ADR-0011): `/public`, `/console` and `/admin` have genuinely different
/// rules, and putting them in one shared layer is how a "super admin" flag
/// ends up leaking a competitor's data.
///
/// This layer does exactly one thing: it turns a [Principal] into a
/// [TenantScope] or refuses the request. Every handler below it therefore
/// **cannot be called without one**, which turns "remember to filter by
/// tenant" from discipline into something the compiler asks about.
///
/// What it does NOT do is check capabilities. Those are per route, because
/// `booking.sell` and `fleet.manage` are held by different people and a
/// blanket check at this level would be the coarsest possible answer to the
/// most granular question in the product.
Handler middleware(Handler handler) =>
    handler.use(_tenantScope()).use(_databaseRequired());

/// Turns "there is no database" into a 503 that says so.
///
/// The fakes composition serves the traveller surface with no Postgres, which
/// is what makes a fresh clone useful. The console cannot work that way — it
/// *configures* the world the traveller browses — so it refuses, and this
/// turns that refusal into an answer naming `DATABASE_URL` rather than the
/// generic 500 the root error boundary would produce.
///
/// Above the tenant scope, so it catches the whole surface including the
/// membership lookup.
Middleware _databaseRequired() =>
    (handler) => (context) async {
      try {
        return await handler(context);
      } on ConsoleRequiresDatabase catch (e) {
        return Response.json(
          statusCode: HttpStatus.serviceUnavailable,
          body: ApiError(
            code: ErrorCode.unavailable,
            params: {'detail': e.toString()},
            traceId: context.read<String>(),
          ).toJson(),
        );
      }
    };

Middleware _tenantScope() =>
    (handler) => (context) async {
      final trace = context.read<String>();
      final principal = context.read<Principal>();

      if (principal.isAnonymous) {
        return _json(
          HttpStatus.unauthorized,
          Problem.unauthorized(traceId: trace),
        );
      }

      final scope = TenantScope.forPrincipal(principal);

      // Authenticated, and not staff of any operator. A traveller who found
      // this URL, or somebody whose membership was revoked between signing in
      // and now — the second is why this is re-read per request rather than
      // trusted from a token claim.
      if (scope == null) {
        return _json(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
      }

      return handler(context.provide<TenantScope>(() => scope));
    };

Response _json(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
