import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/vitrine` — your storefront.
/// `PUT /console/v1/vitrine` — change it.
///
/// The step where an operator stops feeling like a row in somebody else's
/// database and starts feeling like their own business on the platform
/// (`03-operator-lifecycle.md` §2.4). Cheap to build and worth more than it
/// costs, which is why it ships before the refund wizard.
///
/// **Everything here is bounded, and every bound is refused server-side.** The
/// console offers eight accents and three patterns; this route is what makes
/// that true for a caller who is not the console:
///
///   * an unknown accent or pattern is a **400 naming the field**, not a
///     silent fallback. A storefront quietly rendered in the house green when
///     an operator asked for indigo is a support call nobody can reproduce;
///   * a title over 30 characters or a tagline over 60 is a **400 with the
///     limit**, because those lengths are what keep a header from wrapping on
///     a 320 dp screen, which is the screen this is read on.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();
  final storefronts = services.storefronts;

  switch (context.request.method) {
    case HttpMethod.get:
      // Any staff member may look at their own storefront. Only
      // `vitrineManage` may change it.
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final vitrine = await storefronts.forOperator(scope.operatorId);
      if (vitrine == null) {
        return _error(HttpStatus.notFound, Problem.notFound(traceId: trace));
      }
      return _ok(services.withAssetUrls(vitrine), trace);

    case HttpMethod.put:
      final denied = Require.capability(context, Capability.vitrineManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final request = SaveVitrineRequest.fromJson(body);

      final invalid = _refuse(request, trace);
      if (invalid != null) return invalid;

      final saved = await storefronts.save(
        operatorId: scope.operatorId,
        edit: request,
      );
      if (saved == null) {
        return _error(HttpStatus.notFound, Problem.notFound(traceId: trace));
      }
      return _ok(services.withAssetUrls(saved), trace);

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

/// The closed sets, read from the contract rather than from a list copied
/// into this file. The eight hues exist because each one is verified for
/// contrast in direct sun; a ninth spelled here would be a hue nothing ever
/// checked, and the database's own CHECK constraint would refuse it with a
/// 500 rather than a sentence naming the field.
Response? _refuse(SaveVitrineRequest request, String trace) {
  if (!Vitrine.isAccent(request.accentHue)) {
    return _badField('accentHue', request.accentHue, trace);
  }
  if (!Vitrine.isPattern(request.headerPattern)) {
    return _badField('headerPattern', request.headerPattern, trace);
  }

  for (final (field, value, max) in [
    ('titleFr', request.titleFr, SaveVitrineRequest.titleMax),
    ('titleEn', request.titleEn, SaveVitrineRequest.titleMax),
    ('taglineFr', request.taglineFr, SaveVitrineRequest.taglineMax),
    ('taglineEn', request.taglineEn, SaveVitrineRequest.taglineMax),
  ]) {
    if ((value?.trim().length ?? 0) > max) {
      return _error(
        HttpStatus.badRequest,
        ApiError(
          code: ErrorCode.badRequest,
          params: {'field': field, 'max': max},
          traceId: trace,
        ),
      );
    }
  }
  return null;
}

Response _badField(String field, String value, String trace) => _error(
  HttpStatus.badRequest,
  ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field, 'value': value},
    traceId: trace,
  ),
);

Response _ok(VitrineDto vitrine, String trace) => Response.json(
  body: vitrine.toJson(),
  headers: {
    BelHeaders.traceId: trace,
    HttpHeaders.cacheControlHeader: 'private, no-store',
  },
);

Response _error(int status, ApiError error) =>
    Response.json(statusCode: status, body: error.toJson());
