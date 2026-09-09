import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart';

/// `PATCH  /console/v1/staff/<id>` — change an existing member's roles or
/// stations, without going through the phone lookup again.
/// `DELETE /console/v1/staff/<id>` — revoke, instantly: the identity
/// surface's staff join already filters on `revoked_at`, so their very next
/// request is a member of the public, not their last one re-read from a
/// stale token.
Future<Response> onRequest(RequestContext context, String id) async {
  final denied = Require.capability(context, Capability.staffManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.patch:
      final body = await context.request.json() as Map<String, Object?>;

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

      // Blank is no number, not the empty string: a unique index would
      // happily accept `''` twice at one company and then read as a driver
      // number on a manifest.
      final rawRef = body['staffRef'];
      if (rawRef != null && rawRef is! String) {
        return badRequest(trace, 'staffRef');
      }
      final staffRef = (rawRef as String?)?.trim();

      final updated = await services.console.updateStaffAssignment(
        operatorId: scope.operatorId,
        staffId: id,
        roles: roles.toList(),
        stationIds: stationIds,
        staffRef: staffRef == null || staffRef.isEmpty ? null : staffRef,
      );

      // 409, not 400: the request is well formed and the world will not
      // accept it — somebody else at this company already answers to that
      // number.
      if (updated.refTaken) {
        return Response.json(
          statusCode: HttpStatus.conflict,
          body: ApiError(
            code: ErrorCode.staffRefTaken,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      if (updated.staff == null) {
        return Response.json(
          statusCode: HttpStatus.notFound,
          body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response.json(
        body: staffDto(updated.staff!).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.delete:
      final revoked = await services.console.revokeStaff(
        operatorId: scope.operatorId,
        staffId: id,
      );

      if (!revoked) {
        return Response.json(
          statusCode: HttpStatus.notFound,
          body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response(statusCode: HttpStatus.noContent);

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}
