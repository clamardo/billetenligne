import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Liveness. Kept dependency-free on purpose: a health check that queries the
/// database reports "unhealthy" during a brief database blip and takes the
/// whole fleet out of the load balancer with it. Readiness is a separate
/// concern, checked at /ready.
Response onRequest(RequestContext context) =>
    Response.json(statusCode: HttpStatus.ok, body: const {'status': 'ok'});
