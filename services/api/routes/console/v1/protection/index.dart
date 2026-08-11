import 'dart:io';

import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET` the agreements this operator is a party to · `POST` to propose one
/// (`08-disruption.md` §5).
///
/// **Reading needs only `booking.read`.** A dispatcher has to see that option
/// ③ exists — and whether the ceiling has room — before a breakdown, not
/// after. **Writing needs `protection.manage`**, which a dispatcher does not
/// hold: agreeing a standing rate with a competitor is a commercial decision,
/// and the person at the roadside at 05:00 is not the person who makes it.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final agreements = await services.protection.agreementsFor(
        scope.operatorId,
      );
      return Response.json(
        body: {
          'items': [for (final a in agreements) agreementDto(a).toJson()],
        },
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.protectionManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final request = ProposeAgreementRequest.fromJson(body);

      // Parsed here rather than in the adapter, so a corridor that goes
      // nowhere is a 400 with the offending value rather than a 500 from a
      // constructor deep inside a transaction.
      final corridors = <Corridor>[];
      for (final key in request.corridors) {
        try {
          corridors.add(Corridor.parse(key));
        } on ArgumentError {
          return Response.json(
            statusCode: HttpStatus.badRequest,
            body: ApiError(
              code: ErrorCode.badRequest,
              fieldErrors: {'corridors': key},
              traceId: trace,
            ).toJson(),
            headers: {BelHeaders.traceId: trace},
          );
        }
      }

      final result = await services.protection.propose(
        operatorId: scope.operatorId,
        counterpartyCode: request.counterpartyCode,
        corridors: corridors,
        actorUserId: context.read<Principal>().userId,
        reciprocal: request.reciprocal,
        rebillDiscountBps: request.rebillDiscountBps,
        monthlyCapSeats: request.monthlyCapSeats,
        autoAcceptWhenSpareAbove: request.autoAcceptWhenSpareAbove,
      );

      if (result.refusal case final refusal?) {
        return refusedAgreement(refusal, trace);
      }

      return Response.json(
        statusCode: HttpStatus.created,
        body: agreementDto(result.agreement!).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

ProtectionAgreementDto agreementDto(ProtectionAgreementView view) =>
    ProtectionAgreementDto(
      id: view.agreement.id,
      counterpartyId: view.counterpartyId,
      counterpartyName: view.counterpartyName,
      state: view.agreement.state.name,
      corridors: [for (final c in view.agreement.corridors) c.key],
      reciprocal: view.agreement.reciprocal,
      rebillDiscountBps: view.agreement.rebillDiscountBps,
      weProposed: view.weProposed,
      proposedAt: view.proposedAt,
      seatsUsedThisMonth: view.seatsUsedThisMonth,
      monthlyCapSeats: view.agreement.monthlyCapSeats,
      autoAcceptWhenSpareAbove: view.agreement.autoAcceptWhenSpareAbove,
      acceptedAt: view.acceptedAt,
      endedAt: view.endedAt,
      endedReason: view.endedReason,
    );

/// A refusal is a 409 rather than a 400: the request was well-formed and the
/// world said no. The distinction matters to a client deciding whether to fix
/// the payload or tell the user something.
Response refusedAgreement(AgreementRefusal refusal, String trace) =>
    Response.json(
      statusCode: HttpStatus.conflict,
      body: ApiError(
        code: refusal.code,
        params: refusal.params,
        traceId: trace,
      ).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
