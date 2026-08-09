import 'dart:io';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// The market the client is operating in: currency, dialling code, carrier
/// prefixes, service fee and the available payment rails.
///
/// Fetched at startup and cached against its ETag. Serving rails from here
/// rather than compiling them into the app is what lets us enable Orange
/// Money, or fix a renumbered prefix, without an app release (ADR-0006) —
/// which matters because many users in this market never update.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final dto = MarketDto.fromDomain(Market.current);
  final body = dto.toJson();

  // A 304 costs about 200 bytes. On a metered prepaid bundle that is a
  // feature, not a micro-optimisation.
  final etag = '"${_weakHash(body.toString())}"';
  if (context.request.headers[CacheHeaders.ifNoneMatch] == etag) {
    return Response(statusCode: HttpStatus.notModified);
  }

  return Response.json(body: body, headers: {CacheHeaders.etag: etag});
}

String _weakHash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(16);
}
