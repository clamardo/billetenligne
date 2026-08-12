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

  // Paying the difference on a change rather than the journey itself. The
  // rails are the same — same operator, same accounts — and only the amount
  // differs, so this is a parameter rather than a second endpoint that would
  // have to be kept in step with this one forever.
  final changeId = context.request.uri.queryParameters['change'];
  final order = changeId == null
      ? null
      : await services.reschedules.orderById(
          changeId: changeId,
          userId: principal.userId,
        );
  if (changeId != null && (order == null || !order.isAwaitingPayment)) {
    return _error(HttpStatus.notFound, Problem.notFound(traceId: trace), trace);
  }

  final accounts = await services.payForBooking.railsFor(booking.operatorId);
  final account = await services.directory.byAuthUid(principal.authUid);

  // The carrier the traveller's own number belongs to, used only to ORDER the
  // list. A hint, never a restriction: paying from another carrier's wallet is
  // refused by the rail, and the app says which before anything is sent.
  final ownCarrier = account?.phone == null
      ? null
      : PhoneNumber.parse(
          account!.phone!,
          table: services.market.msisdn,
        ).valueOrNull?.operator;
  final recommendedRail = ownCarrier == null
      ? null
      : services.market.railForOperator(ownCarrier)?.id;

  final options = <PaymentOptionDto>[];
  for (final a in accounts) {
    // A rail this deployment cannot reach is not offered. Present-and-broken
    // is worse than absent: it is a button that takes a PIN and loses it.
    if (!services.railIds.contains(a.railId)) continue;

    final rail = services.market.railById(a.railId);

    // A rail the configured market does not describe is still offered, and
    // that is deliberate: ADR-0006 makes this list server-driven precisely so
    // a rail can be added without an app release, and gating it on the file
    // would put a verified account behind a config push. The market entry
    // supplies the label and the USSD fallback when there is one; without it
    // the rail id is the key, which the catalog can grow an entry for at any
    // time.
    if (rail != null && !rail.enabled) continue;

    final checkout = services.checkoutRails.contains(a.railId);

    options.add(
      PaymentOptionDto(
        railId: a.railId,
        operatorId: rail?.operator?.id ?? a.railId,
        // A catalog key. The server never sends prose (ADR-0008).
        labelKey: rail?.labelKey ?? 'enum.PaymentRail.${a.railId}',
        collectionMsisdn: a.msisdn,
        collectionName: a.displayName,
        // Only where there is a menu to dial. A rail whose answer arrives on
        // a web page has no USSD fallback, and offering one would send
        // somebody into a menu that knows nothing about this payment.
        ussdCode: checkout ? null : rail?.ussdCode,
        // Orange Money is mobile money AND a hosted checkout, which is
        // exactly why this is read from the deployment's gateway rather than
        // from the rail's `kind`: the screen has to draw the shape the rail
        // actually is, not the category it belongs to.
        hostedCheckout: checkout,
        recommended: a.railId == recommendedRail,
      ),
    );
  }

  // Card, which has no collection account to be derived from.
  //
  // Every rail above is an operator's own verified wallet; a card settles into
  // the PSP's merchant account and is paid on to the operator by the ordinary
  // payout run — the same route a mobile-money capture takes once it has
  // cleared. So it cannot come out of `railsFor`, and it is appended here
  // under both halves of the same switch every other rail passes: the market
  // file has to offer it, and this deployment has to be able to collect on it.
  for (final rail in services.market.rails) {
    if (rail.kind != PaymentRailKind.card) continue;
    if (!rail.enabled || !services.railIds.contains(rail.id)) continue;

    options.add(
      PaymentOptionDto(
        railId: rail.id,
        operatorId: rail.id,
        labelKey: rail.labelKey,
        // No wallet at either end. Empty rather than a placeholder number: a
        // screen that showed one would be showing somebody a merchant account
        // that does not exist.
        collectionMsisdn: '',
        collectionName: '',
        hostedCheckout: true,
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
      'amount': Wire.money(order?.owed ?? booking.total),
    },
    headers: {
      BelHeaders.traceId: trace,
      // A merchant number and the traveller's own. Never shared-cached.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
