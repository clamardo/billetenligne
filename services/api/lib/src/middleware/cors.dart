import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import '../infrastructure/web/web_origins.dart';

/// Lets the console and the back office call this API from a browser.
///
/// **What was broken.** There was no `Access-Control-Allow-Origin` header
/// anywhere in this tree. That is invisible to every test that builds its own
/// request and to every client that is not a browser — the handset apps and
/// the scanner send no `Origin` at all — and fatal to the two Flutter web
/// apps this product ships: a bundle on `console.blt.cg` calling an API on
/// `blt.cg` is blocked before the request leaves, and so is `flutter run -d
/// chrome` on `localhost:5000` calling `localhost:8080`.
///
/// **Outermost, on purpose.** It wraps the trace id, the error boundary and
/// authentication, for two reasons. A preflight is an `OPTIONS` to a route
/// that has no `OPTIONS` handler, so it has to be answered *before* routing
/// or it becomes a 405 with no CORS headers — which a browser reports as a
/// CORS failure with no further detail. And a 401 or a 500 needs the header
/// as much as a 200 does: without it the browser hides the response, and the
/// console shows "network error" for what was actually "your session
/// expired".
///
/// **An allow-list, echoed exactly, never a wildcard.** See [WebOrigins] for
/// why. Nothing here is derived from the request except the lookup key.
Middleware cors(WebOrigins origins) =>
    (handler) => (context) async {
      final origin = context.request.headers['origin'];

      // No list configured, or a caller that is not a browser. Unchanged
      // behaviour, and no header that would tell a stranger the list exists.
      if (origins.isEmpty || !origins.allows(origin)) {
        return handler(context);
      }

      final headers = <String, String>{
        'Access-Control-Allow-Origin': origin!,
        // The answer depends on who asked. A cache that missed this would
        // serve one origin's response to another and, more often, serve a
        // header-less response to an allowed origin.
        'Vary': 'Origin',
        // Deliberately absent: `Access-Control-Allow-Credentials`. This API
        // authenticates with a bearer token in a header, never with a cookie,
        // and allowing credentials would opt every one of these origins into
        // sending them.
      };

      // The preflight. Answered here rather than routed, because no route in
      // this tree has an OPTIONS handler and a 405 with no CORS headers is
      // what a browser reports as an opaque CORS failure.
      if (context.request.method == HttpMethod.options &&
          context.request.headers['access-control-request-method'] != null) {
        return Response(
          statusCode: HttpStatus.noContent,
          headers: {
            ...headers,
            'Access-Control-Allow-Methods': 'GET, POST, PATCH, PUT, DELETE',
            // Named rather than reflected. A reflected list allows whatever
            // the caller asked for, which is the header equivalent of `*`.
            'Access-Control-Allow-Headers': [
              HttpHeaders.authorizationHeader,
              HttpHeaders.contentTypeHeader,
              HttpHeaders.acceptHeader,
              HttpHeaders.ifNoneMatchHeader,
              BelHeaders.idempotencyKey,
              BelHeaders.language,
              BelHeaders.traceId,
              BelHeaders.reason,
              BelHeaders.appVersion,
              BelHeaders.deviceId,
            ].join(', '),
            // Ten minutes. Long enough that a dispatcher clicking through the
            // console is not paying for a preflight on every action, short
            // enough that changing this list is not a day-long rollout.
            'Access-Control-Max-Age': '600',
          },
        );
      }

      final response = await handler(context);
      return response.copyWith(
        headers: {
          ...response.headers,
          ...headers,
          // Without this a browser hands the client a response it cannot read
          // the interesting parts of: the trace id that connects a bug report
          // to a log line, the flag that says a POST was a replay rather than
          // a second charge, and the filename of a statement being saved.
          'Access-Control-Expose-Headers': [
            BelHeaders.traceId,
            BelHeaders.idempotencyReplayed,
            CacheHeaders.etag,
            HttpHeaders.contentDisposition,
            HttpHeaders.retryAfterHeader,
          ].join(', '),
        },
      );
    };
