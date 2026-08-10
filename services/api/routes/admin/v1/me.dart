import 'dart:io';

import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /admin/v1/me` — who this is, and what they may do here.
///
/// The back office renders its navigation from the capability list, exactly
/// as the console does. And exactly as there, **the list is a hint**: every
/// route below re-checks, because a client that decides what it may do is a
/// client an attacker can edit.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final principal = context.read<Principal>();
  // Reading it proves the middleware ran: there is no path to this handler
  // that is not platform staff with a stated reason.
  context.read<PlatformScope>();

  return Response.json(
    body: AdminIdentityDto(
      userId: principal.userId,
      role: principal.platformRole!,
      capabilities:
          Capability.forRoles([principal.platformRole!], platform: true).toList()
            ..sort(),
    ).toJson(),
    headers: {
      BelHeaders.traceId: context.read<String>(),
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
