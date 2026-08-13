import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/web/storefront_page.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /o/{code}` — an operator's storefront, as a page.
///
/// Off `/public/v1` for the same reason `/t/{token}` is: this is a URL a
/// person reads out, prints on the side of a coach and pastes into a WhatsApp
/// bio. `blt.cg/o/ODN` survives all three; `blt.cg/public/v1/operators/ODN`
/// survives none of them.
///
/// The JSON at that second address has existed since the vitrine shipped and
/// nothing rendered it — so an operator could choose a colour, a pattern, a
/// logo and a cover, press save, and have nowhere to send anybody. The console
/// even calls the screen *votre vitrine*. This is the window.
///
/// **Rendered from the same read the JSON serves**, not from a second query:
/// two ways to answer "what does this company look like" is two ways for them
/// to disagree, and the one the public sees would be the one nobody checks.
Future<Response> onRequest(RequestContext context, String code) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final services = context.read<Services>();
  final language =
      (context.request.uri.queryParameters['lang'] ?? 'fr').startsWith('en')
      ? 'en'
      : 'fr';

  final storefront = await services.storefronts.byCode(code);

  // A suspended operator's storefront is a 404 rather than a page, and that is
  // the database's doing rather than a branch here (migration 0005). A page
  // that outlives the right to sell invites somebody to book from a company we
  // have stopped.
  if (storefront == null) {
    return Response(
      statusCode: HttpStatus.notFound,
      body: StorefrontPage.notFound(
        catalog: Services.translations,
        language: language,
      ),
      headers: _headers(cache: 'public, max-age=60'),
    );
  }

  return Response(
    body: StorefrontPage.render(
      storefront: StorefrontDto(
        vitrine: services.withAssetUrls(storefront.vitrine),
        routes: storefront.routes,
        onTimeRate: storefront.onTimeRate,
      ),
      catalog: Services.translations,
      language: language,
      origin: _origin(context),
    ),
    // Five minutes, matching the JSON endpoint behind it. A poster campaign
    // must not become a load test, and "à partir de" must not be yesterday's
    // price.
    headers: _headers(cache: 'public, max-age=300'),
  );
}

Map<String, Object> _headers({required String cache}) => {
  HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
  HttpHeaders.cacheControlHeader: cache,
  // Not ours to frame. Unlike the follower page there is no referrer policy:
  // this page *wants* to be linked from, and an operator should be able to see
  // in their own analytics that the traffic came from their poster's QR code.
  'X-Frame-Options': 'DENY',
};

/// Where this deployment answers, for the absolute URLs Open Graph requires.
///
/// Read from the request rather than from a variable, because the same binary
/// serves `blt.cg` and a developer's `localhost:8080` and a crawler is
/// reading neither one from configuration.
String _origin(RequestContext context) {
  final uri = context.request.uri;
  final host = context.request.headers['host'] ?? uri.authority;
  final scheme = context.request.headers['x-forwarded-proto'] ?? uri.scheme;
  return host.isEmpty ? '' : '$scheme://$host';
}
