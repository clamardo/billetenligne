import 'dart:io';

import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/roles` — this operator's own roles, and the default
/// roles (`Capability.operatorRoles`) any of them may be cloned from.
/// `POST /console/v1/roles` — clone or design one.
///
/// Both need `staff.manage`, the same capability the Personnel screen gates
/// on — deciding what a role *means* is the same authority as deciding who
/// holds one. [CustomRoleDefinition.validate] additionally restricts POST to
/// a whole-org caller: `staff.manage` is also held by `station_manager`, and
/// a station manager may staff their own till without ever being able to
/// compose what a role grants.
Future<Response> onRequest(RequestContext context) async {
  final denied = Require.capability(context, Capability.staffManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.get:
      final roles = await services.console.customRoles(scope.operatorId);
      return Response.json(
        body: {
          'items': [for (final r in roles) customRoleDto(r).toJson()],
          'defaults': [
            for (final entry in Capability.operatorRoles.entries)
              DefaultRoleDto(
                name: entry.key,
                capabilities: entry.value.toList()..sort(),
              ).toJson(),
          ],
        },
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.post:
      final body = await context.request.json() as Map<String, Object?>;

      final rawName = body['name'];
      if (rawName is! String || rawName.trim().isEmpty) {
        return badRequest(trace, 'name');
      }
      final name = rawName.trim();

      final rawCapabilities = body['capabilities'];
      if (rawCapabilities is! List || rawCapabilities.isEmpty) {
        return badRequest(trace, 'capabilities');
      }
      final capabilities = {for (final c in rawCapabilities) '$c'};

      final clonedFromRole = body['clonedFromRole'] as String?;

      final refusal = CustomRoleDefinition.validate(
        name: name,
        capabilities: capabilities,
        callerCapabilities: scope.capabilities,
        callerIsWholeOrg: scope.stationIds.isEmpty,
      );
      if (refusal != null) return refusedCustomRole(refusal, trace);

      final created = await services.console.createCustomRole(
        operatorId: scope.operatorId,
        name: name,
        capabilities: capabilities.toList(),
        clonedFromRole: clonedFromRole,
      );

      if (created == null) {
        return Response.json(
          statusCode: HttpStatus.conflict,
          body: ApiError(
            code: ErrorCode.customRoleNameInUse,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response.json(
        statusCode: HttpStatus.created,
        body: customRoleDto(created).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

CustomRoleDto customRoleDto(CustomRoleSummary r) => CustomRoleDto(
  id: r.id,
  name: r.name,
  capabilities: r.capabilities,
  clonedFromRole: r.clonedFromRole,
  createdAt: r.createdAt,
);

/// [CustomRoleRefusal] straight onto the wire — one reason, one code, no
/// second vocabulary invented in the route.
Response refusedCustomRole(CustomRoleRefusal refusal, String trace) {
  final code = switch (refusal) {
    CustomRoleRefusal.callerNotWholeOrg =>
      ErrorCode.customRoleCallerNotWholeOrg,
    CustomRoleRefusal.nameRequired => ErrorCode.customRoleNameRequired,
    CustomRoleRefusal.nameCollidesWithDefault =>
      ErrorCode.customRoleNameCollidesWithDefault,
    CustomRoleRefusal.noCapabilities => ErrorCode.customRoleNoCapabilities,
    CustomRoleRefusal.exceedsOwnCapabilities =>
      ErrorCode.customRoleExceedsOwnCapabilities,
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
