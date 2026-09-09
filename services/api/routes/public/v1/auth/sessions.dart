import 'dart:io';

import 'package:bel_api/src/application/second_factor_sign_in.dart';
import 'package:bel_api/src/application/ports/user_directory.dart';
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
  final trace = context.read<String>();
  final services = context.read<Services>();

  // Signing out, which for a browser session has to happen **on the server**:
  // a page that only forgot its cookie would leave a live session behind that
  // anybody holding the old value could still spend.
  if (context.request.method == HttpMethod.delete) {
    return _signOut(context, services, trace);
  }

  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final body = await context.request.json() as Map<String, Object?>;
  final request = VerifySignInRequest.fromJson(body);

  final result = await services.signIn.complete(request);

  return switch (result) {
    Err(:final SignInFailure failure) => _error(
      Problem.statusFor(failure.code),
      Problem.fromFailure(failure, traceId: trace),
      trace,
    ),
    Ok(:final value) => await _issue(
      context,
      services,
      value,
      webSession: request.webSession,
      trace: trace,
    ),
  };
}

Future<Response> _issue(
  RequestContext context,
  Services services,
  SignedIn signedIn, {
  required bool webSession,
  required String trace,
}) async {
  final account = signedIn.account;
  final step = await services.secondFactor.stepFor(account);

  // No session yet. The half-session is signed rather than stored — it is
  // single-purpose, five minutes long, and useless without a code the holder
  // still has to compute, so a row in a table would buy nothing but a table.
  if (step case SecondFactorProve(:final halfSession)) {
    return _session(
      SessionDto(
        mfaToken: halfSession,
        isNewAccount: signedIn.isNewAccount,
        account: _profile(account),
      ),
      trace,
    );
  }

  // The Firebase UID is our account id. We choose it rather than letting
  // Firebase mint one, because the alternative is a round trip to Firebase in
  // the middle of the sign-in transaction — and a failure there would leave an
  // account nobody can ever sign in to.
  final token = await context.read<AuthGateway>().mintCustomToken(
    uid: account.authUid ?? account.id,
  );

  // Asked for by a browser, which has nowhere safe to keep a credential
  // (J11). The exchange happens on the server and the refresh token never
  // crosses the network to the page; what the page gets is a cookie it
  // cannot read.
  if (webSession) {
    final selector = await services.openWebSession(
      userId: account.id,
      customToken: token,
      userAgent: context.request.headers[HttpHeaders.userAgentHeader],
      ip: context.request.headers['x-forwarded-for']?.split(',').first.trim(),
    );

    if (selector != null) {
      return _session(
        SessionDto(
          cookieSession: true,
          mustEnrolSecondFactor: step is SecondFactorMustEnrol,
          isNewAccount: signedIn.isNewAccount,
          account: _profile(account),
        ),
        trace,
        setCookie: services.sessionCookie.issue(
          selector,
          ttl: Services.webSessionTtl,
        ),
      );
    }
    // This deployment cannot keep one — no database, or no way to exchange.
    // Answering with the token is the honest fallback rather than a refusal:
    // the caller asked for the safer shape and gets the working one, and the
    // difference is visible in `cookieSession`.
  }

  return _session(
    SessionDto(
      customToken: token,
      // Staff with nothing enrolled sign in and land on the enrolment screen
      // and nowhere else. Refusing the session instead would have locked out
      // every existing staff account the hour this shipped — including the
      // people who would have to fix it.
      mustEnrolSecondFactor: step is SecondFactorMustEnrol,
      isNewAccount: signedIn.isNewAccount,
      account: _profile(account),
    ),
    trace,
  );
}

/// `DELETE /public/v1/auth/sessions` — end this browser's session.
///
/// Always 204, whether or not there was one to end. Signing out twice is
/// signing out, and an answer that distinguished the two would tell somebody
/// holding a guessed cookie that they had guessed a real one.
///
/// The cookie is cleared in the same response, with every attribute identical
/// to the one that issued it — a browser matches a deletion by name, domain
/// and path, and a clear that differs in any of them leaves the original in
/// place.
Future<Response> _signOut(
  RequestContext context,
  Services services,
  String trace,
) async {
  final selector = services.sessionCookie.read(context.request.headers);
  if (selector != null) await services.webSessions.revoke(selector);

  return Response(
    statusCode: HttpStatus.noContent,
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.setCookieHeader: services.sessionCookie.clear(),
    },
  );
}

AccountDto _profile(Account account) => AccountDto(
  id: account.id,
  language: account.language,
  email: account.email,
  phone: account.phone,
  fullName: account.fullName,
);

Response _session(SessionDto session, String trace, {String? setCookie}) =>
    Response.json(
      statusCode: HttpStatus.ok,
      body: session.toJson(),
      headers: {
        BelHeaders.traceId: trace,
        if (setCookie != null) HttpHeaders.setCookieHeader: setCookie,
      },
    );

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
