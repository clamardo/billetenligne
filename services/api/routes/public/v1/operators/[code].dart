import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/operators/{code}` — an operator's storefront.
///
/// The page behind `blt.cg/o/ODN`: the hero, the lines they run and the
/// cheapest fare on each. Anonymous, deep-linkable, and the natural landing
/// page for an operator's own WhatsApp and poster campaigns
/// (`03-operator-lifecycle.md` §2.4). Carries enough to book from rather than
/// being a brochure, which is the difference between a marketing page and a
/// sales channel.
///
/// **404 for an operator who is not selling**, and that is the database's
/// doing rather than a branch here: the public role's policy is
/// `app_is_public() AND status = 'active'` (migration 0005). A suspended
/// operator's storefront invites somebody to book from a company we have
/// stopped, and a page that outlives the right to sell is worse than a dead
/// link.
Future<Response> onRequest(RequestContext context, String code) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();
  final storefront = await services.storefronts.byCode(code);

  if (storefront == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: Problem.notFound(traceId: trace).toJson(),
    );
  }

  return Response.json(
    body: StorefrontDto(
      vitrine: services.withAssetUrls(storefront.vitrine),
      routes: storefront.routes,
      onTimeRate: storefront.onTimeRate,
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      // Five minutes. A vitrine changes a handful of times a year and the
      // next departure changes hourly, so this is the shorter of the two
      // clocks — long enough that a poster campaign does not become a load
      // test, short enough that "à partir de" is not yesterday's price.
      HttpHeaders.cacheControlHeader: 'public, max-age=300',
    },
  );
}
