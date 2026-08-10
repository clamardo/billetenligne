import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/payment-accounts` — where we collect for you.
/// `POST /console/v1/payment-accounts` — set the number.
///
/// The number every traveller's francs land in. Three things guard it:
///
///   * **`settlementAccountEdit`, not `fleetManage`.** Redirecting where the
///     money goes is the highest-value fraud against a platform like this
///     (ADR-0011), so only the owner may, and it is the one capability
///     `org_admin` does not carry.
///   * **Saved unverified, always.** A mobile money transfer has no
///     chargeback: a typo here sends every franc to a stranger, permanently.
///     An operator typing their own number is not proof it is theirs.
///   * **Replacing deactivates rather than edits**, so an intent that already
///     paid into last month's number still resolves in a dispute.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      final denied = Require.capability(context, Capability.financeRead);
      if (denied != null) return denied;

      final accounts = await console.paymentAccounts(scope.operatorId);
      return Response.json(
        body: {
          'items': [
            for (final a in accounts)
              {
                'id': a.id,
                'railId': a.railId,
                'msisdn': a.msisdn,
                'displayName': a.displayName,
                // Said plainly. Until this is true the rail is offered to
                // nobody, and a number that looks live but is not is worse
                // than no number at all.
                'verified': a.verified,
              },
          ],
          // Which rails could be configured at all, so the console offers a
          // closed list rather than a free-text rail id.
          'availableRails': [
            for (final rail in Market.current.rails)
              if (rail.kind == PaymentRailKind.mobileMoney)
                {'railId': rail.id, 'labelKey': rail.labelKey},
          ],
        },
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final denied = Require.capability(
        context,
        Capability.settlementAccountEdit,
      );
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final railId = body['railId'];
      final msisdn = body['msisdn'];
      final displayName = body['displayName'];

      if (railId is! String) return _badRequest(trace, 'railId');
      if (displayName is! String || displayName.trim().isEmpty) {
        return _badRequest(trace, 'displayName');
      }

      // Parsed and normalised to E.164 before it is stored. A number kept as
      // typed is a number the rail will not recognise, and the failure
      // surfaces months later as "the operator never got paid".
      final parsed = PhoneNumber.parse('$msisdn');
      if (parsed case Err(:final failure)) {
        return Response.json(
          statusCode: HttpStatus.badRequest,
          body: ApiError(
            code: failure.code,
            params: failure.params,
            traceId: trace,
          ).toJson(),
          headers: {BelHeaders.traceId: trace},
        );
      }

      final saved = await console.savePaymentAccount(
        operatorId: scope.operatorId,
        railId: railId,
        msisdn: parsed.valueOrNull!.e164,
        displayName: displayName.trim(),
      );

      if (saved == null) return _badRequest(trace, 'railId');

      return Response.json(
        statusCode: HttpStatus.created,
        body: {
          'id': saved.id,
          'railId': saved.railId,
          'msisdn': saved.msisdn,
          'displayName': saved.displayName,
          'verified': saved.verified,
        },
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);
