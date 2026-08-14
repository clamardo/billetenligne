import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET /ready` — may this pod be sent traffic.
///
/// **A different question from `/health`, and the difference is the whole
/// reason this file exists.** `/health` is dependency-free on purpose: it
/// answers *is this process alive and what is it wired to*, and a liveness
/// probe that queried the database would restart the entire fleet during a
/// database blip — turning a thirty-second outage into a cold start on every
/// pod at once, which is the failure mode that outage was not going to have.
///
/// Readiness is the opposite trade. A pod that cannot reach Postgres cannot
/// serve a search, a sale or a boarding pass, and taking it out of the load
/// balancer while it cannot is exactly right: the traffic goes to a pod that
/// can, and the pod comes back the moment the database does. Nothing is
/// restarted.
///
/// One round trip, no role and no tenant. What is being asked is whether a
/// connection can be got and used — not whether the schema is correct, which
/// a probe could not act on anyway.
///
/// With no database this answers ready, because the fakes composition serves
/// invented departures and has nothing to be unready about.
Future<Response> onRequest(RequestContext context) async {
  final services = context.read<Services>();
  final ready = await services.isReady;

  return Response.json(
    statusCode: ready ? HttpStatus.ok : HttpStatus.serviceUnavailable,
    body: {
      'ready': ready,
      'data': services.usingDatabase ? 'postgres' : 'fakes',
    },
    // Never cached, by anything, for any length of time. A cached readiness
    // answer is a load balancer being told about the state of the world some
    // seconds ago, which is the one thing this endpoint must not be.
    headers: {HttpHeaders.cacheControlHeader: 'no-store'},
  );
}
