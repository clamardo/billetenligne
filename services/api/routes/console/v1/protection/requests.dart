import 'dart:io';

import 'package:bel_api/src/application/ports/protection_desk.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

import 'index.dart';

/// `GET` the protection requests this operator is a party to · `POST` to ask
/// another company for room (`08-disruption.md` §2.2 option ③, §2.3).
///
/// Asking needs `disruption.declare`, not `protection.manage`: this is the
/// roadside decision, and the person taking it is the dispatcher. Agreeing
/// the *terms* is a different capability, held by different people, because
/// committing the company to a standing rate is not a 05:40 decision.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final requests = await services.protection.requestsFor(scope.operatorId);
      return Response.json(
        body: {
          'items': [for (final r in requests) requestDto(r).toJson()],
        },
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.disruptionDeclare);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final request = ProtectionRequestBody.fromJson(body);

      final result = await services.protection.request(
        operatorId: scope.operatorId,
        departureId: request.departureId,
        replacementDepartureId: request.replacementDepartureId,
        actorUserId: context.read<Principal>().userId,
        now: services.clock.now(),
        note: request.note,
      );

      if (result.refusal case final refusal?) {
        return refusedAgreement(refusal, trace);
      }

      return Response.json(
        statusCode: HttpStatus.created,
        body: requestDto(result.request!).toJson(),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

ProtectionRequestDto requestDto(ProtectionRequestView view) =>
    ProtectionRequestDto(
      id: view.id,
      agreementId: view.agreementId,
      counterpartyName: view.counterpartyName,
      weAsked: view.weAsked,
      fromDepartureId: view.fromDepartureId,
      toDepartureId: view.toDepartureId,
      seatsRequested: view.seatsRequested,
      state: view.state,
      requestedAt: view.requestedAt,
      note: view.note,
      routeCode: view.routeCode,
      departsAt: view.departsAt,
      replacementDepartsAt: view.replacementDepartsAt,
      seatsFree: view.seatsFree,
      rebill: view.rebill,
      autoAccepted: view.autoAccepted,
      seatsMoved: view.seatsMoved,
      declineReason: view.declineReason,
    );
