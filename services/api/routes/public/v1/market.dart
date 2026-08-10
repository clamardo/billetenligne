import 'dart:convert';
import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/request_headers.dart';
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

  final body = MarketDto.fromDomain(
    Market.current,
    // A fact about today's deployment, not about the country. The app renders
    // a phone option only when there is a sender to send from, so the day a
    // number is provisioned is a config push rather than a release (ADR-0006)
    // — which matters here, where a large share of users never update.
    signInChannels: [
      'email',
      if (context.read<Services>().smsConfigured) 'phone',
    ],
  ).toJson();
  // Hash the canonical JSON, not `toString()`: a map's debug representation is
  // not a stable serialisation contract.
  final etag = '"${_weakHash(jsonEncode(body))}"';

  // A 304 costs about 200 bytes against ~1.1 KB. On a metered prepaid bundle
  // that is a feature, not a micro-optimisation.
  if (context.request.headers.matchesEtag(etag)) {
    return Response(
      statusCode: HttpStatus.notModified,
      headers: {CacheHeaders.etag: etag},
    );
  }

  return Response.json(body: body, headers: {CacheHeaders.etag: etag});
}

String _weakHash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h = ((h ^ c) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(16);
}
