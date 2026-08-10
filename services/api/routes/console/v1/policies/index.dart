import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/application/ports/operator_console.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET  /console/v1/policies` — every refund policy this operator has written.
/// `POST /console/v1/policies` — write one, or a new version of one.
///
/// **A POST is always an insert.** ADR-0015 rule 1 is the most important rule
/// in that document and the one most systems get wrong: a booking stores the
/// policy version it was sold under and is judged by that version forever.
/// Editing in place would silently change what somebody who has already paid
/// is entitled to — so a name that already exists gets the next version, and
/// since 0014 the database has revoked `UPDATE` on the table besides.
///
/// The **prose is not sent**. The wire carries the structured terms and both
/// ends call `RefundPolicy.describe()` to render them, which is what
/// guarantees the sentences a traveller reads before paying are generated
/// from the numbers the server executes at cancellation (ADR-0015 rule 3).
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final console = context.read<Services>().console;

  switch (context.request.method) {
    case HttpMethod.get:
      // Readable by anyone who can see a booking: a vendor at the counter is
      // asked "can I get my money back?" far more often than an owner is.
      final denied = Require.capability(context, Capability.bookingRead);
      if (denied != null) return denied;

      final policies = await console.refundPolicies(scope.operatorId);
      return Response.json(
        body: {
          'items': [for (final p in policies) _json(p)],
          // Said explicitly rather than inferred from an empty `isDefault`
          // across the list: an operator with no default sells with no policy
          // at all, and the console has to be able to say that out loud.
          'hasDefault': policies.any((p) => p.isDefault),
        },
        headers: {
          BelHeaders.traceId: trace,
          HttpHeaders.cacheControlHeader: 'private, no-store',
        },
      );

    case HttpMethod.post:
      final denied = Require.capability(context, Capability.policyManage);
      if (denied != null) return denied;

      final body = await context.request.json() as Map<String, Object?>;
      final name = body['name'];
      if (name is! String || name.trim().isEmpty) {
        return _badRequest(trace, 'name');
      }

      final parsed = _policyFrom(body);
      if (parsed.policy == null) return _badRequest(trace, parsed.field!);

      final saved = await console.saveRefundPolicy(
        operatorId: scope.operatorId,
        name: name.trim(),
        policy: parsed.policy!,
        actorUserId: context.read<Principal>().userId,
      );

      return Response.json(
        statusCode: HttpStatus.created,
        body: _json(saved),
        headers: {BelHeaders.traceId: trace},
      );

    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Map<String, Object?> _json(RefundPolicySummary summary) =>
    RefundPolicyDto.fromDomain(
      summary.policy,
      name: summary.name,
      isDefault: summary.isDefault,
      bookingCount: summary.bookingCount,
    ).toJson();

/// The request body as a policy, or the field that made it impossible.
///
/// Every refusal names its field, because a wizard with six questions and a
/// bare 400 sends an operator back to guess which answer we disliked.
({RefundPolicy? policy, String? field}) _policyFrom(Map<String, Object?> body) {
  final rawTiers = body['tiers'];
  // An absent list is a typo; an empty one is a policy that refunds nothing,
  // which is a real answer an operator is entitled to give.
  if (rawTiers is! List) return (policy: null, field: 'tiers');
  if (rawTiers.length > 6) return (policy: null, field: 'tiers');

  final tiers = <RefundTier>[];
  for (var i = 0; i < rawTiers.length; i++) {
    final entry = rawTiers[i];
    if (entry is! Map) return (policy: null, field: 'tiers[$i]');
    final tier = entry.cast<String, Object?>();

    final minutes = tier['minLeadTimeMinutes'];
    // A year of lead time is not a policy anybody wrote on purpose.
    if (minutes is! int || minutes < 0 || minutes > 525600) {
      return (policy: null, field: 'tiers[$i].minLeadTimeMinutes');
    }

    final rate = tier['rateBps'];
    if (rate is! int || rate < 0 || rate > 10000) {
      return (policy: null, field: 'tiers[$i].rateBps');
    }

    final flatFee = tier['flatFeeMinor'] ?? 0;
    if (flatFee is! int || flatFee < 0) {
      return (policy: null, field: 'tiers[$i].flatFeeMinor');
    }

    tiers.add(
      RefundTier(
        minLeadTime: Duration(minutes: minutes),
        rateBps: rate,
        flatFeeMinor: flatFee,
      ),
    );
  }

  final destination = RefundDestination.values
      .where((d) => d.name == body['destination'])
      .firstOrNull;
  if (body['destination'] != null && destination == null) {
    return (policy: null, field: 'destination');
  }

  final hours = body['processingHours'] ?? 72;
  // Thirty days. Beyond that it is not a processing window, it is a way of
  // never paying — and the platform floor exists precisely so an operator
  // cannot write one.
  if (hours is! int || hours < 0 || hours > 720) {
    return (policy: null, field: 'processingHours');
  }

  final refundFee = body['refundServiceFee'] ?? false;
  if (refundFee is! bool) return (policy: null, field: 'refundServiceFee');

  final fares = body['nonRefundableFares'] ?? const [];
  if (fares is! List) return (policy: null, field: 'nonRefundableFares');

  final policy = RefundPolicy(
    // Overwritten by the adapter, which either continues an existing policy's
    // id or mints one. Nothing downstream reads this value.
    id: 'pending',
    version: 0,
    tiers: tiers,
    destination: destination ?? RefundDestination.source,
    processingWindow: Duration(hours: hours),
    refundServiceFee: refundFee,
    nonRefundableFareCodes: {for (final f in fares) '$f'},
  );

  // The check that is not about typing. Tiers are matched **in order**, so a
  // list written shortest-first answers every request with its most generous
  // band — and nobody notices until the month's refunds are counted.
  if (!policy.isWellFormed) return (policy: null, field: 'tiers');

  return (policy: policy, field: null);
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
