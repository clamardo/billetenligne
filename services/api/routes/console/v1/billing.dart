import 'dart:io';

import 'package:bel_api/src/application/ports/platform_billing_rail.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /console/v1/billing` — what this operator owes the platform this
/// month, and how to pay it.
/// `PUT /console/v1/billing` — change which rail to pay with.
///
/// The platform's own bill, entirely separate from the payout run
/// (`04-payments.md` §6.2 note): an operator reads this and a payout at the
/// same time and the two numbers do not net against each other, because they
/// are not the same debt.
Future<Response> onRequest(RequestContext context) async {
  final denied = Require.capability(context, Capability.billingManage);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  switch (context.request.method) {
    case HttpMethod.get:
      return _billingResponse(services, scope.operatorId, trace);

    case HttpMethod.put:
      final body = await context.request.json() as Map<String, Object?>;
      final request = SetBillingPaymentTypeRequest.fromJson(body);

      final principal = context.read<Principal>();
      final result = await services.billing.setPaymentType(
        operatorId: scope.operatorId,
        paymentType: request.paymentType,
        actorUserId: principal.userId,
      );

      final refusal = result.failureOrNull;
      if (refusal != null) {
        return Response.json(
          statusCode: HttpStatus.badRequest,
          body: ApiError(
            code: refusal.code,
            params: {'paymentType': request.paymentType},
            traceId: trace,
          ).toJson(),
        );
      }

      return _billingResponse(services, scope.operatorId, trace);

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Future<Response> _billingResponse(
  Services services,
  String operatorId,
  String trace,
) async {
  final charge = await services.billing.currentCharge(operatorId);
  final paymentType = await services.billing.paymentType(operatorId);

  final rail = services.billingRails[paymentType];
  final instruction = rail == null
      ? const PlatformBillingInstruction(available: false)
      : await rail.instructionsFor(
          operatorId: operatorId,
          amountDue: charge.amount,
          reference: _reference(operatorId, charge.periodStart),
        );

  return Response.json(
    body: PlatformBillingDto(
      operatorId: operatorId,
      periodStart: charge.periodStart,
      periodEnd: charge.periodEnd,
      amountDue: charge.amount,
      status: charge.status,
      paymentType: paymentType,
      available: instruction.available,
      checkoutUrl: instruction.checkoutUrl,
      bankName: instruction.bankName,
      bankAccountName: instruction.accountName,
      bankAccountNumber: instruction.accountNumber,
      reference: instruction.reference,
    ).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// What a human reconciling an incoming wire, or a Stripe dashboard, sees
/// against this charge. Built from the operator id and the period rather
/// than the charge's own uuid, so it stays readable enough to read out over
/// the phone.
String _reference(String operatorId, DateTime periodStart) =>
    'BEL-${operatorId.substring(0, 8)}-'
    '${periodStart.year}${periodStart.month.toString().padLeft(2, '0')}';
