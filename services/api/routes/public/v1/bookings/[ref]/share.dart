import 'dart:io';

import 'package:bel_api/src/application/ports/trip_sharing.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_trip_sharing.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `GET · POST · DELETE /public/v1/bookings/<ref>/share` — the shareable trip
/// link (ADR-0014 §2).
///
/// The ask is specific and very common here: somebody travelling the 512 km
/// of the RN1, and a relative at the far end deciding when to leave for the
/// station. Today that costs phone credit and repeated calls.
///
/// **POST is idempotent without an idempotency key.** Sharing twice returns
/// the link that already exists rather than minting a second one — two live
/// links would mean one the traveller cannot see in order to revoke it, which
/// is the opposite of the control this feature promises. The plaintext token
/// therefore comes back exactly once, on the response that created it.
Future<Response> onRequest(RequestContext context, String ref) async {
  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  if (principal.isAnonymous) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: Problem.unauthorized(traceId: trace).toJson(),
      headers: {BelHeaders.traceId: trace},
    );
  }

  final parsed = BookingRef.parse(ref).valueOrNull;
  if (parsed == null) return _unknown(trace);

  return switch (context.request.method) {
    HttpMethod.get => _read(services, parsed.value, principal, trace),
    HttpMethod.post => _create(services, parsed.value, principal, trace),
    HttpMethod.delete => _revoke(services, parsed.value, principal, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _read(
  Services services,
  String ref,
  Principal principal,
  String trace,
) async {
  final share = await services.sharing.shareFor(
    bookingRef: ref,
    userId: principal.userId,
  );

  // 404 rather than an empty object: "you have not shared this" and "there is
  // no such booking" are the same shape to a caller and the screen asks the
  // same question of both.
  if (share == null) return _unknown(trace);

  return Response.json(
    body: _dto(services, share).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Future<Response> _create(
  Services services,
  String ref,
  Principal principal,
  String trace,
) async {
  final result = await services.sharing.share(
    bookingRef: ref,
    userId: principal.userId,
    now: services.clock.now(),
  );

  if (result.failureOrNull case final refusal?) {
    return _refused(refusal, trace);
  }

  final share = result.valueOrNull!;
  return Response.json(
    // 201 only when a link was actually minted. An unchanged one is a 200,
    // so a client can tell "here is your existing link" from "here is a new
    // one" without comparing tokens.
    statusCode: share.token == null ? HttpStatus.ok : HttpStatus.created,
    body: _dto(services, share).toJson(),
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Future<Response> _revoke(
  Services services,
  String ref,
  Principal principal,
  String trace,
) async {
  final result = await services.sharing.revoke(
    bookingRef: ref,
    userId: principal.userId,
    now: services.clock.now(),
  );

  if (result.failureOrNull case final refusal?) {
    return _refused(refusal, trace);
  }

  return Response(
    statusCode: HttpStatus.noContent,
    headers: {BelHeaders.traceId: trace},
  );
}

TripShareDto _dto(Services services, TripShare share) {
  final sharing = services.sharing;
  return TripShareDto(
    // The URL is built here rather than in the store, because where a link
    // points is a deployment fact and the store's job was to mint a secret.
    url: share.token == null || sharing is! PostgresTripSharing
        ? null
        : sharing.urlFor(share.token!).toString(),
    expiresAt: share.expiresAt,
    opens: share.opens,
    revoked: share.revoked,
  );
}

Response _refused(ShareRefusal refusal, String trace) => Response.json(
  statusCode: switch (refusal) {
    UnknownShare() => HttpStatus.notFound,
    NothingToShare() => HttpStatus.conflict,
    ShareExpired() || ShareRevoked() => HttpStatus.gone,
  },
  body: ApiError(code: refusal.code, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);

Response _unknown(String trace) => Response.json(
  statusCode: HttpStatus.notFound,
  body: ApiError(code: ErrorCode.bookingInvalidRef, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
