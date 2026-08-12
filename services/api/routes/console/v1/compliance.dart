import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/compliance` — how long this operator's paperwork has left.
///
/// What the full-width banner is drawn from. It starts appearing at thirty
/// days and stops being dismissible at zero, and the reason it exists is the
/// asymmetry: we can see an insurance certificate lapsing sixty days out, and
/// the company that would lose a day's sales over it usually cannot.
///
/// **No capability check.** Every role in the console may read this — a
/// dispatcher who cannot open the fleet screen still needs to know why the
/// sales they are making are about to stop, and a banner that only the
/// director can see is a banner that appears the week after they went on
/// leave. Nothing here is confidential to the company that owns it: a
/// document type and a date.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final scope = context.read<TenantScope>();
  final standing = await context.read<Services>().compliance.standing(
    scope.operatorId,
  );

  return Response.json(
    body: standing.toJson(),
    headers: {
      BelHeaders.traceId: context.read<String>(),
      // The day a document lapses, the banner has to change on the next
      // page load. A cached copy is a company still being told it has a week.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}
