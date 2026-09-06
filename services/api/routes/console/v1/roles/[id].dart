import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_platform/bel_platform.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart';

/// `PATCH  /console/v1/roles/<id>` — rename this role and/or replace its
/// capability set.
/// `DELETE /console/v1/roles/<id>` — remove it, refused while any active
/// staff member still carries it (`OperatorConsole.deleteCustomRole`).
Future<Response> onRequest(RequestContext context, String id) async {
  final denied = Require.capability(context, Capability.staffManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.patch:
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

      final refusal = CustomRoleDefinition.validate(
        name: name,
        capabilities: capabilities,
        callerCapabilities: scope.capabilities,
        callerIsWholeOrg: scope.stationIds.isEmpty,
      );
      if (refusal != null) return refusedCustomRole(refusal, trace);

      final result = await services.console.updateCustomRole(
        operatorId: scope.operatorId,
        roleId: id,
        name: name,
        capabilities: capabilities.toList(),
      );

      if (result.nameConflict) {
        return Response.json(
          statusCode: HttpStatus.conflict,
          body: ApiError(
            code: ErrorCode.customRoleNameInUse,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }
      if (result.role == null) {
        return Response.json(
          statusCode: HttpStatus.notFound,
          body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response.json(
        body: customRoleDto(result.role!).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    case HttpMethod.delete:
      final deleted = await services.console.deleteCustomRole(
        operatorId: scope.operatorId,
        roleId: id,
      );

      if (deleted == null) {
        return Response.json(
          statusCode: HttpStatus.notFound,
          body: ApiError(code: ErrorCode.notFound, traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }
      if (!deleted) {
        return Response.json(
          statusCode: HttpStatus.conflict,
          body: ApiError(
            code: ErrorCode.customRoleInUse,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      return Response(statusCode: HttpStatus.noContent);

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}
