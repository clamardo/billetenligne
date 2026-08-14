import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/cors.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// Root middleware: correlation, authentication, and a single place where an
/// unexpected exception becomes a typed error.
///
/// Authorisation is NOT here. It belongs to each surface (`/public`,
/// `/console`, `/admin`), which have genuinely different rules — putting it in
/// one shared layer is how a "super admin" flag ends up leaking a competitor's
/// data (ADR-0011).
/// ORDER MATTERS, and it reads backwards: `.use()` wraps, so the LAST call is
/// the OUTERMOST layer and runs FIRST. Execution is therefore:
///
///   _traceId  ->  _errorBoundary  ->  provider  ->  _authentication  ->  route
///
/// _traceId must be outermost because every layer below it reads the trace id
/// from the context. Getting this inverted turned a 401 into a 500: the auth
/// layer tried to read a trace id that had not been provided yet, and the
/// error boundary was inside the throw rather than around it. Unit tests
/// cannot catch that — only running the server does, which is why
/// tool/smoke_api.sh exists.
Handler middleware(Handler handler) => handler
    .use(_authentication())
    .use(provider<AuthGateway>((_) => _authGateway))
    .use(provider<Services>((_) => _services))
    .use(_errorBoundary())
    .use(_traceId())
    // Outermost of all: a preflight must be answered before routing, and a
    // 401 or a 500 needs the header as much as a 200 does — without it the
    // browser hides the response and the console says "network error" for
    // what was actually "your session expired". See `middleware/cors.dart`.
    .use(cors(_services.webOrigins));

/// Resolved once, at startup. Postgres when DATABASE_URL is set, fakes
/// otherwise — see composition.dart for why that fallback exists.
final Services _services = Services.resolve();

// Chosen by composition, not here: Firebase behind a real database and a
// deterministic fake otherwise (ADR-0018). It moved there when it grew a
// dependency — verifying a token now ends in a `user_accounts` lookup, because
// Firebase answers *who you are* and only our database answers *whether you
// are still a customer*.
final AuthGateway _authGateway = _services.authGateway;

/// Nothing escapes as an untyped 500 with a stack trace in it.
Middleware _errorBoundary() =>
    (handler) => (context) async {
      final trace = context.read<String>();
      try {
        return await handler(context);
      } on FormatException catch (_) {
        return _json(
          HttpStatus.badRequest,
          ApiError(code: ErrorCode.badRequest, traceId: trace),
        );
      } on WireFormatException catch (e) {
        return _json(
          HttpStatus.badRequest,
          ApiError(
            code: ErrorCode.badRequest,
            fieldErrors: {e.field: e.message},
            traceId: trace,
          ),
        );
      } catch (e, s) {
        // The detail goes to the log, never to the client: a stack trace
        // leaks internals and would be in the wrong language anyway. The
        // trace id is what connects the two.
        stderr.writeln('[$trace] unhandled: $e\n$s');
        return _json(
          HttpStatus.internalServerError,
          Problem.internal(traceId: trace),
        );
      }
    };

/// Honours a client-supplied trace id so a failure reported in the app can be
/// found in one search, and mints one otherwise.
Middleware _traceId() =>
    (handler) => (context) async {
      final incoming = context.request.headers[BelHeaders.traceId];
      final trace = (incoming != null && incoming.isNotEmpty)
          ? incoming
          : _mintTraceId();

      final response = await handler(context.provide<String>(() => trace));
      return response.copyWith(
        headers: {...response.headers, BelHeaders.traceId: trace},
      );
    };

/// Resolves a principal if a bearer token is present.
///
/// Absence is not an error here: search, routes, prices and seat maps are all
/// open, and auth is required only at the moment of holding a seat. Forcing
/// sign-up before the user sees value is the biggest avoidable drop-off in
/// this funnel (ADR-0013).
Middleware _authentication() =>
    (handler) => (context) async {
      final header = context.request.headers[HttpHeaders.authorizationHeader];
      var principal = Principal.anonymous;

      if (header != null && header.startsWith('Bearer ')) {
        final resolved = await context.read<AuthGateway>().verify(
          header.substring(7),
        );
        if (resolved == null) {
          return _json(
            HttpStatus.unauthorized,
            Problem.unauthorized(traceId: context.read<String>()),
          );
        }
        principal = resolved;
      }

      return handler(context.provide<Principal>(() => principal));
    };

Response _json(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());

var _counter = 0;
String _mintTraceId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  return '${now.toRadixString(36)}${(_counter++ & 0xfff).toRadixString(36)}';
}
