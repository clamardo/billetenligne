import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET    /console/v1/departures/{id}/crew` — who is on this coach.
/// `POST   /console/v1/departures/{id}/crew` — put somebody on it.
/// `DELETE /console/v1/departures/{id}/crew` — take somebody off it.
///
/// A departure has been a row that inventory is sold against and nothing
/// else, and four separate things the business wants are downstream of that:
/// a driver dashboard has nothing to be a dashboard *of*, GPS has nothing to
/// attach to, closing a departure has nothing to close, and "tell the
/// passenger who has not arrived" has no moment at which somebody is missing.
/// This is the first half — who is on it.
///
/// Behind `departure.manage`, the dispatcher's capability, and deliberately
/// **not** `staff.manage`. The two are different jobs done by different
/// people: a station manager grants somebody the `driver` role, which is a
/// statement about what they are qualified to do; a dispatcher puts them on
/// tomorrow's 06:00, which is a statement about a coach. Collapsing them would
/// hand every rota in the company to whoever can hire.
///
/// **DELETE carries a body**, which is unusual and is the least bad option
/// here. What identifies a roster row is the triple *(departure, person,
/// job)* — one person may legitimately both drive and conduct the same run —
/// and neither of the alternatives is better: a synthetic row id would exist
/// only to be put in a URL, and two query parameters on a DELETE are the same
/// data one layer further from the schema that defines it.
Future<Response> onRequest(RequestContext context, String id) async {
  final denied = Require.capability(context, Capability.departureManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final crew = await console.crew(
        operatorId: scope.operatorId,
        departureId: id,
      );
      return Response.json(
        body: {
          'crew': [for (final member in crew) _dto(member).toJson()],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final parsed = await _read(context);
      if (parsed == null) return _badRequest(trace, 'body');

      final result = await console.assignCrew(
        operatorId: scope.operatorId,
        departureId: id,
        staffUserId: parsed.userId,
        role: parsed.role,
        actorUserId: context.read<Principal>().userId,
      );

      return switch (result) {
        Ok(:final value) => Response.json(
          body: _dto(value).toJson(),
          headers: {BelHeaders.traceId: trace},
        ),
        Err(:final failure) => _refused(trace, failure),
      };

    case HttpMethod.delete:
      final parsed = await _read(context);
      if (parsed == null) return _badRequest(trace, 'body');

      final result = await console.unassignCrew(
        operatorId: scope.operatorId,
        departureId: id,
        staffUserId: parsed.userId,
        role: parsed.role,
      );

      return switch (result) {
        // False means there was nothing to remove, which is the same outcome
        // the caller wanted and not an error. A dispatcher who taps twice on
        // a slow connection has said the same thing twice.
        Ok() => Response(statusCode: HttpStatus.noContent),
        Err(:final failure) => _refused(trace, failure),
      };

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

CrewMemberDto _dto(CrewMember member) => CrewMemberDto(
  userId: member.userId,
  role: member.role.name,
  assignedAt: member.assignedAt,
  fullName: member.fullName,
  staffRef: member.staffRef,
  phone: member.phone,
);

/// Null when the body is unusable — including an unknown job, which is read
/// here rather than passed through as a string: the port takes a [CrewRole],
/// so a typo cannot reach the database as a role nobody has capabilities for.
Future<({String userId, CrewRole role})?> _read(RequestContext context) async {
  try {
    final body = await context.request.json() as Map<String, Object?>;
    final userId = body['userId'];
    final role = CrewRole.byName(body['role'] as String?);
    if (userId is! String || userId.isEmpty || role == null) return null;
    return (userId: userId, role: role);
  } on Object {
    return null;
  }
}

/// One `ErrorCode` per [CrewAssignmentRefusal], so the pure rule's vocabulary
/// reaches the wire without a second one being invented for the same reasons.
///
/// 409 rather than 400 throughout: none of these is a malformed request. Each
/// is a well-formed one the world will not accept — this person does not work
/// here, is not qualified, has left, or that coach has already gone.
Response _refused(String trace, CrewAssignmentRefusal refusal) => Response.json(
  statusCode: HttpStatus.conflict,
  body: ApiError(
    code: switch (refusal) {
      CrewAssignmentRefusal.unknownRole => ErrorCode.crewUnknownRole,
      CrewAssignmentRefusal.notStaff => ErrorCode.crewNotStaff,
      CrewAssignmentRefusal.notQualified => ErrorCode.crewNotQualified,
      CrewAssignmentRefusal.revoked => ErrorCode.crewRevoked,
      CrewAssignmentRefusal.departed => ErrorCode.crewDeparted,
    },
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
