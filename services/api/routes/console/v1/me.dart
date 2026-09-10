import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
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
///
/// It also answers *who am I*, which used to be a UUID and nothing else. The
/// name, the matricule and the company are here because three surfaces need
/// them and none of them could get them: the console's identity strip showed
/// a raw id, the admin one did too, and the scanner — a handset issued by an
/// agency and passed between people — had no way to say whose it was. The
/// matricule is an identifier and **never a credential** (ADR-0024).
///
/// One extra query, on a call each app makes once at launch.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final principal = context.read<Principal>();
  final scope = context.read<TenantScope>();

  // A failure here is not a failure to sign in. Everything below it is what
  // the caller may do, which is the part the client cannot work without; a
  // header with no name on it is a cosmetic loss.
  var who = const StaffIdentity();
  try {
    who = await context.read<Services>().console.staffIdentity(
      operatorId: scope.operatorId,
      userId: principal.userId,
    );
  } on Object {
    // Left blank, and the surfaces that show it show nothing.
  }

  return Response.json(
    body: {
      'userId': principal.userId,
      'operatorId': scope.operatorId,
      'roles': principal.roles,
      'stationIds': scope.stationIds,
      'capabilities': Capability.forRoles(principal.roles).toList()..sort(),
      'language': principal.language,
      if (who.fullName != null) 'fullName': who.fullName,
      if (who.staffRef != null) 'staffRef': who.staffRef,
      if (who.operatorName != null) 'operatorName': who.operatorName,
      if (who.operatorCode != null) 'operatorCode': who.operatorCode,
    },
    headers: {
      BelHeaders.traceId: context.read<String>(),
      // Membership changes take effect on the next request. A cached copy of
      // "what may I do" is a dismissed employee's console still working.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
