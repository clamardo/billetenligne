import 'dart:io';

import 'package:bel_api/src/application/second_factor_sign_in.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/auth/sessions/mfa` — the second half of a staff sign-in.
///
/// Takes the half-session this account was handed a moment ago plus a code
/// from their authenticator, and answers with the Firebase custom token the
/// first request withheld.
///
/// A separate route rather than a second field on `/auth/sessions`, because
/// the two steps have genuinely different inputs and genuinely different
/// failures — a wrong emailed code and a wrong authenticator code are not the
/// same event, and a locked factor is not a failed challenge. One route
/// answering both would have to explain which half went wrong in its body,
/// which is exactly the kind of overloading that ends up mis-rendered.
///
/// Anonymous, like the route before it: the caller is proving who they are,
/// so requiring a token to do it would be circular.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final request = VerifySecondFactorRequest.fromJson(body);

  final result = await services.secondFactor.prove(
    halfSession: request.mfaToken,
    code: request.code,
    recoveryCode: request.recoveryCode,
  );

  switch (result) {
    case Err(:final SecondFactorFailure failure):
      return _error(
        Problem.statusFor(failure.code),
        Problem.fromFailure(failure, traceId: trace),
        trace,
      );
    case Ok(:final value):
      final account = await services.directory.byId(value);

      // Proved a factor for an account that no longer exists. Between the two
      // halves of a sign-in somebody was deleted; the honest answer is the
      // same one a bad code gets.
      if (account == null) {
        return _error(
          HttpStatus.unauthorized,
          Problem.unauthorized(traceId: trace),
          trace,
        );
      }

      final token = await context.read<AuthGateway>().mintCustomToken(
        uid: account.authUid ?? account.id,
      );

      return Response.json(
        body: SessionDto(
          customToken: token,
          isNewAccount: false,
          account: AccountDto(
            id: account.id,
            language: account.language,
            email: account.email,
            phone: account.phone,
            fullName: account.fullName,
          ),
        ).toJson(),
        headers: {BelHeaders.traceId: trace},
      );
  }
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
