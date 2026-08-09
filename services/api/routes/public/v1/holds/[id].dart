import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `DELETE /public/v1/holds/{id}` — the traveller backed out.
///
/// Worth building early rather than leaving to the sweeper. A hold released at
/// the moment somebody taps "Retour" is a seat back on sale fifteen minutes
/// sooner, and on a coach that is nearly full those fifteen minutes are a real
/// sale.
///
/// No idempotency key: releasing twice is releasing once, and demanding a key
/// for an operation that is already idempotent is ceremony that clients get
/// wrong.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.delete) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  // Scoped to the owner inside the adapter, so a leaked hold id is not a way
  // to free somebody else's seats. A hold that is not ours and a hold that
  // never existed answer identically on purpose: distinguishing them would
  // turn this endpoint into a way to enumerate other people's bookings.
  final released = await services.inventory.release(
    holdId: id,
    userId: principal.userId,
  );

  return Response(
    statusCode: released ? HttpStatus.noContent : HttpStatus.notFound,
    headers: {BelHeaders.traceId: trace},
  );
}
