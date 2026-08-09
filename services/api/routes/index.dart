import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

/// Root. Deliberately says nothing about versions, tenants or capabilities —
/// the three route surfaces below it are the real API.
Response onRequest(RequestContext context) => Response.json(
  statusCode: HttpStatus.ok,
  body: const {'service': 'billetenligne', 'status': 'ok'},
);
