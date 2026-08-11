import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/web/follower_page.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /t/{token}` — the page a follower opens (ADR-0014 §2).
///
/// Off `/public/v1` deliberately: this is the one URL in the system a human
/// reads out, types, or sees in a WhatsApp preview, and `blt.cg/t/xxxx` is
/// short enough to survive all three. Everything under `/public/v1` is JSON
/// for a client; this is HTML for a person.
///
/// **It renders before it fetches.** The markup and the words come down in one
/// response, and the trip data arrives a moment later — so somebody on a
/// two-bar connection sees a page rather than a white screen, and a dead link
/// still says something kind.
///
/// The token is never validated here. Whether it resolves is the JSON
/// endpoint's business, and a page that 404'd on an unknown token would leak
/// which tokens exist to anybody willing to try a few.
Future<Response> onRequest(RequestContext context, String token) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final language = context.request.uri.queryParameters['lang'] ?? 'fr';

  return Response(
    body: FollowerPage.render(
      token: token,
      catalog: Services.translations,
      language: language.startsWith('en') ? 'en' : 'fr',
    ),
    headers: {
      HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
      // The shell is the same for every follower and changes when we deploy.
      // The trip data behind it is not cached here — that has its own header,
      // on its own endpoint.
      HttpHeaders.cacheControlHeader: 'public, max-age=300',
      // Nothing on this page is ours to frame or to leak a referrer to.
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    },
  );
}
