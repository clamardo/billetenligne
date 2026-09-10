import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/ticket_designs` — the operator's saved stationery.
/// `PUT /console/v1/ticket_designs` — save or update one.
///
/// The vitrine on paper, and the same argument for it: an operator who prints
/// their own header on the ticket a customer carries around a yard stops
/// being a row in somebody else's database. The difference is that this one
/// is also read by a machine at a coach door, so the bounds are tighter and
/// the reasons are physical — a free colour picker guarantees somebody
/// eventually prints a hue that vanishes in direct sun, or a ground behind a
/// code that a cheap scanner refuses.
///
/// **The design vocabulary is validated by the domain, not by a list here.**
/// `TicketDesign.fromJson` is tolerant on purpose — a build that meets a
/// design saved by a newer build must still print a ticket — and the adapter
/// stores what the domain read back rather than what arrived. So a motif this
/// build has never heard of is stored as the fallback, and the console is
/// answered with what is actually live rather than with its own typo.
///
/// What *is* refused here is the name, because it is the operator's own text
/// and nothing downstream trims it.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final designs = context.read<Services>().ticketDesigns;

  switch (context.request.method) {
    case HttpMethod.get:
      // Any staff member may look. Only `vitrineManage` may change it — the
      // ticket is branding, and it is the same authority as the storefront.
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final saved = await designs.forOperator(scope.operatorId);
      return Response.json(
        body: {
          'designs': [for (final d in saved) d.toJson()],
          // The four an operator starts from, sent rather than compiled into
          // the console: the starters are domain constants, and a console
          // that carried its own copy would drift from what the printer
          // actually renders.
          'starters': [
            for (final entry in TicketStarters.keys.entries)
              {'key': entry.key, ...entry.value.toJson()},
          ],
        },
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.put:
      final denied = Require.capability(context, Capability.vitrineManage);
      if (denied != null) return denied;

      final Map<String, Object?> body;
      try {
        body = await context.request.json() as Map<String, Object?>;
      } on FormatException {
        return _badField('body', '', trace);
      } on TypeError {
        return _badField('body', '', trace);
      }

      final request = SaveTicketDesignRequest.fromJson(body);
      final name = request.name.trim();
      if (name.isEmpty || name.length > SaveTicketDesignRequest.nameMax) {
        return _badField('name', name, trace);
      }

      final saved = await designs.save(
        operatorId: scope.operatorId,
        edit: request,
      );
      if (saved == null) {
        return Response.json(
          statusCode: HttpStatus.notFound,
          body: Problem.notFound(traceId: trace).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }
      return Response.json(
        body: saved.toJson(),
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Response _badField(String field, String value, String trace) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field, if (value.isNotEmpty) 'value': value},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
