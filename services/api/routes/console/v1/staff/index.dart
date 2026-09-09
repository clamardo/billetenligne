import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/staff` — everyone who has ever held a key to this
/// console, revoked staff included.
/// `POST /console/v1/staff` — invite somebody by phone, or change an
/// existing member's roles and stations by inviting them again.
///
/// Both need `staff.manage` — held by `org_owner`, `org_admin` and
/// `station_manager` (ADR-0011) — because seeing who can sell a ticket here
/// is the same authority as deciding who can.
///
/// This is the only route that writes `operator_staff.station_ids`. Before
/// this existed nobody could be attached to a till at all.
Future<Response> onRequest(RequestContext context) async {
  final denied = Require.capability(context, Capability.staffManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.get:
      final staff = await services.console.staff(scope.operatorId);
      return Response.json(
        body: {
          'items': [for (final s in staff) staffDto(s).toJson()],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final body = await context.request.json() as Map<String, Object?>;

      final phone = body['phone'];
      if (phone is! String || phone.trim().isEmpty) {
        return badRequest(trace, 'phone');
      }

      final rawRoles = body['roles'];
      if (rawRoles is! List || rawRoles.isEmpty) {
        return badRequest(trace, 'roles');
      }
      final roles = {for (final r in rawRoles) '$r'};

      final rawStations = body['stationIds'];
      if (rawStations != null && rawStations is! List) {
        return badRequest(trace, 'stationIds');
      }
      final stationIds = [
        for (final s in (rawStations as List?) ?? const []) '$s',
      ];

      final customRoles = await services.console.customRoles(scope.operatorId);
      final refusal = StaffAssignment.validate(
        callerIsWholeOrg: scope.stationIds.isEmpty,
        callerStationIds: scope.stationIds,
        requestedRoles: roles,
        requestedStationIds: stationIds,
        customRoleNames: {for (final r in customRoles) r.name},
      );
      if (refusal != null) return refusedAssignment(refusal, trace);

      final number = PhoneNumber.parse(
        phone.trim(),
        table: services.market.msisdn,
      );
      if (number case Err(:final failure)) {
        return Response.json(
          statusCode: HttpStatus.badRequest,
          body: Problem.fromFailure(failure, traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      // Unverified, like any counter sale: the owner typed this number, its
      // owner has not proved it yet, and proving it is what sign-in is for.
      final account = await services.directory.forCounterSale(
        phone: number.valueOrNull!.e164,
        fullName: (body['fullName'] as String?)?.trim(),
      );

      final result = await services.console.inviteStaff(
        operatorId: scope.operatorId,
        accountId: account.id,
        roles: roles.toList(),
        stationIds: stationIds,
      );

      return Response.json(
        statusCode: HttpStatus.created,
        body: staffDto(result.staff!).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

StaffDto staffDto(StaffSummary s) => StaffDto(
  id: s.id,
  userId: s.userId,
  staffRef: s.staffRef,
  phone: s.phone,
  fullName: s.fullName,
  roles: s.roles,
  stationIds: s.stationIds,
  invitedAt: s.invitedAt,
  revokedAt: s.revokedAt,
);

/// [StaffAssignmentRefusal] straight onto the wire — one reason, one code,
/// no second vocabulary invented in the route.
Response refusedAssignment(StaffAssignmentRefusal refusal, String trace) {
  final code = switch (refusal) {
    StaffAssignmentRefusal.noRoles => ErrorCode.staffNoRoles,
    StaffAssignmentRefusal.unknownRole => ErrorCode.staffUnknownRole,
    StaffAssignmentRefusal.roleNotPermitted => ErrorCode.staffRoleNotPermitted,
    StaffAssignmentRefusal.stationRequired => ErrorCode.staffStationRequired,
    StaffAssignmentRefusal.stationNotCovered =>
      ErrorCode.staffStationNotCovered,
  };
  return Response.json(
    statusCode: Problem.statusFor(code),
    body: ApiError(code: code, traceId: trace).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}

Response badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
