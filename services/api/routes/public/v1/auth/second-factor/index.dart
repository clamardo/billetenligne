import 'dart:io';

import 'package:bel_api/src/application/ports/user_directory.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `/public/v1/auth/second-factor` — the authenticator on this account.
///
///   * `GET` — whether one is enrolled, and whether one is owed.
///   * `POST` — begin enrolment: a fresh secret, a QR payload, and eight
///     recovery codes returned exactly once.
///   * `DELETE` — remove it.
///
/// On the **public** surface rather than under `/console` or `/admin`, even
/// though only staff ever call it, because it is a fact about a person's
/// account and not about an operator's business. A vendor who also books
/// their own travel has one authenticator, not one per surface — and putting
/// this behind the console would have meant a second copy under the admin
/// routes, with two chances to disagree about what "enrolled" means.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final services = context.read<Services>();
  final principal = context.read<Principal>();

  if (principal.isAnonymous) return _unauthorized(trace);

  final account = await services.directory.byAuthUid(principal.authUid);
  if (account == null) return _unauthorized(trace);

  return switch (context.request.method) {
    HttpMethod.get => await _status(services, account, trace),
    HttpMethod.post => await _begin(services, account, trace),
    HttpMethod.delete => await _disable(services, account, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _status(
  Services services,
  Account account,
  String trace,
) async {
  final factor = await services.secondFactor.statusFor(account.id);

  return Response.json(
    body: SecondFactorStatusDto(
      // Unconfirmed is not enrolled. Reporting a half-finished enrolment as
      // done would let the console stop nagging somebody who cannot actually
      // produce a code.
      enrolled: factor?.isConfirmed ?? false,
      required_: services.secondFactor.isRequiredFor(account),
      confirmedAt: factor?.confirmedAt,
      recoveryCodesRemaining: factor?.unusedRecoveryCodes ?? 0,
    ).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}

Future<Response> _begin(
  Services services,
  Account account,
  String trace,
) async {
  final enrolment = await services.secondFactor.beginEnrolment(account);

  // Already confirmed. Replacing a working factor is its own act — doing it
  // here would turn a stray click into a lockout of somebody whose phone
  // still holds the old secret.
  if (enrolment == null) {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: ApiError(
        code: ErrorCode.mfaAlreadyEnrolled,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  return Response.json(
    statusCode: HttpStatus.created,
    body: SecondFactorEnrolmentDto(
      secretBase32: enrolment.secretBase32,
      provisioningUri: enrolment.provisioningUri,
      recoveryCodes: enrolment.recoveryCodes,
    ).toJson(),
    headers: {BelHeaders.traceId: trace},
  );
}

/// Removes the factor.
///
/// Allowed on a live session because the alternative — a support ticket — is
/// worse: somebody replacing a lost phone would otherwise spend a day locked
/// into an enrolment they cannot complete. The session that does it was itself
/// gated by the factor being removed, so this is not a bypass.
Future<Response> _disable(
  Services services,
  Account account,
  String trace,
) async {
  await services.secondFactor.disable(account.id);
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
