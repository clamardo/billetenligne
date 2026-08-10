import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /hooks/payments/{rail}` — a rail says something happened.
///
/// **The body is never trusted** (ADR-0005 rule 4). It is used for exactly one
/// thing: finding out *which intent* to ask about. The state then comes from a
/// fresh query to the rail's own API, because anybody who can reach this URL
/// can post a JSON object claiming a capture, and a capture issues a ticket.
///
/// Everything else here follows from that:
///
///   * **It always answers 200**, even for an intent it has never heard of.
///     Rails retry non-2xx aggressively and some disable a callback URL that
///     errors; an unknown reference is far more likely to be a stale retry
///     than a problem worth breaking delivery over.
///   * **It does no work in the response path** beyond the re-query. The
///     traveller is not waiting on this — they are polling.
///   * **The raw body is written to `payment_events` regardless.** When a
///     dispute arrives six weeks later this is the only thing that settles it.
///
/// The rail is in the path rather than sniffed from the body, so a payload
/// shaped like MTN's cannot be replayed against Airtel's parser.
Future<Response> onRequest(RequestContext context, String rail) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final services = context.read<Services>();
  final railId = _railIdFor(rail);

  // Unknown rail: 200 and nothing. Answering 404 to a telco's retry loop is
  // how a callback URL gets disabled.
  if (railId == null || !services.railIds.contains(railId)) {
    return Response(statusCode: HttpStatus.ok);
  }

  Map<String, Object?> body;
  try {
    body = await context.request.json() as Map<String, Object?>;
  } on Object {
    return Response(statusCode: HttpStatus.ok);
  }

  final intentId = _intentIdFrom(body);
  if (intentId == null) return Response(statusCode: HttpStatus.ok);

  // Re-query. The callback told us *that* something happened; the rail's own
  // API is the only thing allowed to say *what*.
  await services.payForBooking.reconcile(
    intentId: intentId,
    railId: railId,
    source: 'callback',
  );

  return Response(statusCode: HttpStatus.ok);
}

String? _railIdFor(String rail) => switch (rail) {
  'mtn' => 'cg.mtn_momo',
  'airtel' => 'cg.airtel_money',
  'fake' => 'cg.fake_money',
  _ => null,
};

/// Digs our intent id out of whatever shape the rail sent.
///
/// MTN echoes the `externalId` we set and keys the transaction on the
/// `X-Reference-Id` we generated; Airtel nests ours at
/// `data.transaction.id`. Both are tried, and neither is trusted for anything
/// beyond selecting a row.
String? _intentIdFrom(Map<String, Object?> body) {
  for (final key in const ['referenceId', 'externalId', 'reference']) {
    final value = body[key];
    if (value is String && value.isNotEmpty) return value;
  }

  final data = (body['data'] as Map?)?.cast<String, Object?>();
  final transaction = (data?['transaction'] as Map?)?.cast<String, Object?>();
  final id = transaction?['id'];
  return id is String && id.isNotEmpty ? id : null;
}
