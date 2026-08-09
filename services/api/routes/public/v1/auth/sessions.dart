import 'dart:io';

import 'package:bel_api/src/application/sign_in.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/auth/sessions` — answer the code, get a credential.
///
/// The answer is a **Firebase custom token**, not a session of ours. The app
/// exchanges it with Firebase for an ID token and a refresh token, and every
/// request after this one carries the ID token.
///
/// That split is the whole design (ADR-0018's documented fallback): we own the
/// challenge, so the code travels over a channel we can measure and price;
/// Firebase owns the session, the refresh rotation and the revocation, none of
/// which we then have to write. Answering with a bearer of our own invention
/// here would quietly take all three on.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final services = context.read<Services>();

  final body = await context.request.json() as Map<String, Object?>;
  final request = VerifySignInRequest.fromJson(body);

  final result = await services.signIn.complete(request);

  return switch (result) {
    Err(:final SignInFailure failure) => _error(
      Problem.statusFor(failure.code),
      Problem.fromFailure(failure, traceId: trace),
      trace,
    ),
    Ok(:final value) => await _issue(context.read<AuthGateway>(), value, trace),
  };
}

Future<Response> _issue(
  AuthGateway gateway,
  SignedIn signedIn,
  String trace,
) async {
  final account = signedIn.account;

  // The Firebase UID is our account id. We choose it rather than letting
  // Firebase mint one, because the alternative is a round trip to Firebase in
  // the middle of the sign-in transaction — and a failure there would leave an
  // account nobody can ever sign in to.
  final token = await gateway.mintCustomToken(uid: account.authUid ?? account.id);

  return Response.json(
    statusCode: HttpStatus.ok,
    body: SessionDto(
      customToken: token,
      isNewAccount: signedIn.isNewAccount,
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

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
