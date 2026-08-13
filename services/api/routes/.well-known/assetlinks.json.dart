import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/web/app_link_claims.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /.well-known/assetlinks.json` — Android App Links (ADR-0026).
///
/// The domain's half of the handshake: the app declares `blt.cg`, this file
/// declares the app, and Android verifies the pair before it will open
/// `blt.cg/b/{token}` in the app rather than a browser.
///
/// **Served rather than deployed as a static file.** It has to come from the
/// same origin as the links themselves, and a JSON file in a bucket is a file
/// that goes missing on the day somebody changes hosting — which fails
/// silently, months later, as "the link stopped opening the app".
///
/// Public and long-cached: it is the same three lines for every caller and
/// Android fetches it rarely.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final identity = context.read<Services>().appLinks;

  return Response(
    body: AppLinkClaims.assetLinks(
      androidPackage: identity.androidPackage,
      fingerprints: identity.androidFingerprints,
    ),
    headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
      HttpHeaders.cacheControlHeader: 'public, max-age=3600',
    },
  );
}
