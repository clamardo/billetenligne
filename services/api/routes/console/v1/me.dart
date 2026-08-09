import 'dart:io';

import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/me` — who this is, and what they may do.
///
/// The console renders its navigation from the capability list rather than
/// from role names, which is the same rule the server checks by (ADR-0011):
/// a vendor never sees a Fleet tab, and adding a role is a configuration row
/// rather than a release on both sides.
///
/// **This list is a hint, not an authority.** Every route re-checks, because a
/// client that decides what it may do is a client an attacker can edit.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final principal = context.read<Principal>();
  final scope = context.read<TenantScope>();

  return Response.json(
    body: {
      'userId': principal.userId,
      'operatorId': scope.operatorId,
      'roles': principal.roles,
      'stationIds': scope.stationIds,
      'capabilities': Capability.forRoles(principal.roles).toList()..sort(),
      'language': principal.language,
    },
    headers: {
      BelHeaders.traceId: context.read<String>(),
      // Membership changes take effect on the next request. A cached copy of
      // "what may I do" is a dismissed employee's console still working.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
