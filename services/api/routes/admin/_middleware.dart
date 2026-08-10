import 'dart:io';

import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// The admin surface: our own back office, reading and writing across tenants.
///
/// A third set of rules, deliberately not shared with `/public` or `/console`
/// (ADR-0011). The thing this layer exists to guarantee is narrow and it is
/// the whole reason the surface is separate: **nothing below it can run
/// without a [PlatformScope], and a PlatformScope cannot exist without a
/// stated reason.**
///
/// The reason travels in `X-Bel-Reason`. That is a deliberate choice over a
/// body field:
///
///   * a GET has no body, and cross-tenant *reads* are exactly what
///     ADR-0011 asks to be attributable — "who looked at this operator's
///     revenue, and why" is a question that gets asked after the fact;
///   * one place to read it means one place that can forget to.
///
/// Reads fall back to a stated default when the header is absent, because a
/// queue screen that cannot list a queue without typing a sentence is a
/// screen nobody uses — and the actor, the subject and the time are recorded
/// either way. **Writes have no fallback**: a decision without a reason is
/// refused with a 400 that says which header is missing.
Handler middleware(Handler handler) => handler.use(_platformScope());

/// Reads carry this when the caller states nothing better. It is honest — a
/// reviewer working the queue is doing exactly this — and it keeps the
/// *actor* on every row, which is the part that cannot be reconstructed.
const defaultReadReason = 'back office review';

/// Spelled once, in the contracts package, so the back office and this
/// middleware cannot disagree about it.
const reasonHeader = BelHeaders.reason;

Middleware _platformScope() =>
    (handler) => (context) async {
      final trace = context.read<String>();
      final principal = context.read<Principal>();

      if (principal.isAnonymous) {
        return _json(
          HttpStatus.unauthorized,
          Problem.unauthorized(traceId: trace),
        );
      }

      // Authority first, then the paperwork. A traveller or an operator's
      // staff who found this URL learns only that they may not be here — not
      // that there is a header they could have sent. (And somebody whose
      // platform role was revoked between signing in and now, which is why
      // this is re-read per request rather than trusted from a token claim.)
      if (!principal.isPlatform || principal.platformRole == null) {
        return _json(HttpStatus.forbidden, Problem.forbidden(traceId: trace));
      }

      final stated = context.request.headers[reasonHeader]?.trim() ?? '';
      final mutating = context.request.method != HttpMethod.get;

      // A refusal that names the header, rather than a 403 that leaves one of
      // our own people guessing which of their credentials is wrong.
      if (mutating && stated.isEmpty) {
        return _json(
          HttpStatus.badRequest,
          ApiError(
            code: ErrorCode.badRequest,
            params: const {'field': reasonHeader},
            traceId: trace,
          ),
        );
      }

      final scope = PlatformScope.forPrincipal(
        principal,
        reason: stated.isEmpty ? defaultReadReason : stated,
      )!;

      return handler(context.provide<PlatformScope>(() => scope));
    };

Response _json(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
