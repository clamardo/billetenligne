import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:dart_frog/dart_frog.dart';

/// Liveness, and what this process is actually wired to.
///
/// Kept dependency-free on purpose: a health check that queries the database
/// reports "unhealthy" during a brief database blip and takes the whole fleet
/// out of the load balancer with it. Readiness is a separate concern.
///
/// **The wiring is here because its absence cost an evening.** With no
/// `DATABASE_URL` the API serves the in-memory composition — deliberately, so
/// a fresh clone runs — and it answers 200, lists invented departures and
/// writes the sign-in code to its own stdout. A launcher whose env file
/// quietly did not apply produces exactly that, and everything looks like it
/// is working: the console signs in, the search returns coaches, and the mail
/// catcher stays empty for a reason nobody can see. One request now says so.
///
/// Nothing here is a secret. It is which *kind* of thing is connected, never
/// a host, an account or a key: `smtp` rather than the server, `postgres`
/// rather than the connection string.
Response onRequest(RequestContext context) {
  final services = context.read<Services>();
  return Response.json(
    statusCode: HttpStatus.ok,
    body: {
      'status': 'ok',
      'data': services.usingDatabase ? 'postgres' : 'fakes',
      // Where email goes. `log` means stdout and an empty Mailpit.
      'mail': services.mailChannel,
      'storage': services.storage.isConfigured ? 'objects' : 'memory',
      'market': services.market.code,
    },
  );
}
