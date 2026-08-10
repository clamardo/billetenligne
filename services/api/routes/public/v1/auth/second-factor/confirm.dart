import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/auth/second-factor/confirm` — prove the app works.
///
/// Enrolment is not finished by scanning a QR code; it is finished by
/// computing a code from it. Until this succeeds the stored secret is inert,
/// and that is the point: a row marked confirmed the moment a secret was
/// generated would lock somebody out of the console with a secret their phone
/// never received.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();
  final principal = context.read<Principal>();

  if (principal.isAnonymous) return _unauthorized(trace);

  final account = await services.directory.byAuthUid(principal.authUid);
  if (account == null) return _unauthorized(trace);

  final body = await context.request.json() as Map<String, Object?>;
  final confirmed = await services.secondFactor.confirmEnrolment(
    userId: account.id,
    code: Wire.requireString(body['code'], 'code'),
  );

  if (!confirmed) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: ApiError(
        code: ErrorCode.mfaIncorrect,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response(
    statusCode: HttpStatus.noContent,
    headers: {BelHeaders.traceId: trace},
  );
}

Response _unauthorized(String trace) => Response.json(
  statusCode: HttpStatus.unauthorized,
  body: Problem.unauthorized(traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
