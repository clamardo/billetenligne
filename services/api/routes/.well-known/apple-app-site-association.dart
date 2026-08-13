import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/web/app_link_claims.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /.well-known/apple-app-site-association` — Universal Links (ADR-0026).
///
/// The same handshake as Android's, with two details Apple gets to have and
/// which are the usual way this file is served wrong:
///
///   * **No `.json` extension**, which is why this route's name has none.
///   * **`application/json`, unsigned.** The signed CMS form has not been
///     required since iOS 9, and serving one is a way to be broken on a
///     platform that no longer reads it.
///
/// Only `/b/*` is claimed. The follower page at `/t/` is opened by strangers
/// with no account and no app, and an operating system offering to install one
/// would be answering a question nobody asked.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  return Response(
    body: AppLinkClaims.appleAppSiteAssociation(
      appleAppId: context.read<Services>().appLinks.appleAppId,
    ),
    headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
      HttpHeaders.cacheControlHeader: 'public, max-age=3600',
    },
  );
}
