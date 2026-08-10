import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /public/v1/bookings/{id}/payment-options` — how can I pay for this?
///
/// **Server-driven, and intersected three ways** (ADR-0006): a rail is offered
/// only if this deployment holds credentials for it, the operator has a live
/// verified collection account on it, and the market lists it. Enabling
/// Orange Money is then a config push rather than an app release — which
/// matters because a meaningful share of users in this market never update
/// the app.
///
/// Each option carries **the number the money goes to and the name beside
/// it**. Paying a number you do not recognise is the moment people abandon,
/// and digits with no name attached are what a scam looks like.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  if (principal.isAnonymous) {
    return _error(
      HttpStatus.unauthorized,
      Problem.unauthorized(traceId: trace),
      trace,
    );
  }

  final bookings = await services.bookings.forTraveller(principal.userId);
  final booking = bookings.where((b) => b.id == id).firstOrNull;

  // Not theirs, or not a booking. One answer.
  if (booking == null) {
    return _error(HttpStatus.notFound, Problem.notFound(traceId: trace), trace);
  }

  final accounts = await services.payForBooking.railsFor(booking.operatorId);
  final account = await services.directory.byAuthUid(principal.authUid);

  // The carrier the traveller's own number belongs to, used only to ORDER the
  // list. A hint, never a restriction: paying from another carrier's wallet is
  // refused by the rail, and the app says which before anything is sent.
  final ownCarrier = account?.phone == null
      ? null
      : PhoneNumber.parse(account!.phone!).valueOrNull?.operator;
  final recommendedRail = ownCarrier == null
      ? null
      : Market.current.railForOperator(ownCarrier)?.id;

  final options = <PaymentOptionDto>[];
  for (final a in accounts) {
    // A rail this deployment cannot reach is not offered. Present-and-broken
    // is worse than absent: it is a button that takes a PIN and loses it.
    if (!services.railIds.contains(a.railId)) continue;

    final rail = _railFor(a.railId);

    // A rail the compiled-in market does not describe is still offered, and
    // that is deliberate: ADR-0006 makes this list server-driven precisely so
    // a rail can be added without an app release, and gating it on a constant
    // in the binary would defeat that. The market entry supplies the label
    // and the USSD fallback when there is one; without it the rail id is the
    // key, which the catalog can grow an entry for at any time.
    if (rail != null && !rail.enabled) continue;

    options.add(
      PaymentOptionDto(
        railId: a.railId,
        operatorId: rail?.operator?.id ?? a.railId,
        // A catalog key. The server never sends prose (ADR-0008).
        labelKey: rail?.labelKey ?? 'enum.PaymentRail.${a.railId}',
        collectionMsisdn: a.msisdn,
        collectionName: a.displayName,
        ussdCode: rail?.ussdCode,
        recommended: a.railId == recommendedRail,
      ),
    );
  }

  options.sort((a, b) {
    if (a.recommended == b.recommended) return 0;
    return a.recommended ? -1 : 1;
  });

  return Response.json(
    body: {
      'items': [for (final o in options) o.toJson()],
      // Their own number, so the app can prefill it and mark the "paying from
      // somebody else's wallet" toggle honestly.
      if (account?.phone != null) 'accountMsisdn': account!.phone,
      'amount': Wire.money(booking.total),
    },
    headers: {
      BelHeaders.traceId: trace,
      // A merchant number and the traveller's own. Never shared-cached.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

PaymentRail? _railFor(String railId) {
  for (final rail in Market.current.rails) {
    if (rail.id == railId) return rail;
  }
  return null;
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
