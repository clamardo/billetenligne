import 'dart:io';

import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `PUT /console/v1/vitrine/{logo|cover}` — upload one.
/// `DELETE /console/v1/vitrine/{logo|cover}` — remove it.
///
/// **Raw bytes with a `Content-Type`, not multipart.** A logo is one file with
/// no accompanying fields, and multipart would mean parsing a boundary
/// protocol to recover exactly the bytes an ordinary request body already
/// carries. The type header is read for nothing: what we store and what we
/// later serve is decided by sniffing the bytes, because a caller who could
/// choose the served type could have a PNG served as `text/html`.
///
/// Answers with the whole vitrine rather than a URL, so the editor's live
/// preview re-renders from one response instead of stitching a new URL into
/// state it already holds.
Future<Response> onRequest(RequestContext context, String asset) async {
  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();

  final kind = switch (asset) {
    'logo' => BrandAssetKind.logo,
    'cover' => BrandAssetKind.cover,
    _ => null,
  };
  if (kind == null) {
    return _json(
      HttpStatus.notFound,
      Problem.notFound(traceId: trace),
      trace,
    );
  }

  final denied = Require.capability(context, Capability.vitrineManage);
  if (denied != null) return denied;

  return switch (context.request.method) {
    HttpMethod.put => await _upload(context, services, scope, kind, trace),
    HttpMethod.delete => await _remove(services, scope, kind, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _upload(
  RequestContext context,
  Services services,
  TenantScope scope,
  BrandAssetKind kind,
  String trace,
) async {
  if (!services.storage.isConfigured) {
    // Distinct from a refusal: nothing the caller sent was wrong, and telling
    // them their PNG was invalid would send them off to re-export a file that
    // was fine.
    return _json(
      HttpStatus.serviceUnavailable,
      ApiError(code: ErrorCode.storageUnavailable, traceId: trace),
      trace,
    );
  }

  final bytes = await context.request.bytes().expand((chunk) => chunk).toList();

  final inspected = BrandAsset.inspect(bytes, kind: kind);
  if (inspected.problem case final problem?) return _refused(problem, kind, trace);

  final accepted = inspected.asset!;

  // Keyed by operator and kind, so a second upload replaces the first. A
  // versioned key would leave every old logo readable forever by anybody who
  // had ever seen its URL — and the extension is part of the key because a
  // browser fetching `logo` with no extension is a browser guessing.
  final key = 'operators/${scope.operatorId}/${kind.name}.${accepted.extension}';

  await services.storage.put(
    key: key,
    bytes: accepted.bytes,
    contentType: accepted.contentType,
  );

  // Storage first, then the row. The other order would point the storefront at
  // a file that does not exist yet; this one leaves at worst an orphaned blob,
  // which costs a fraction of a centime and shows nobody a broken image.
  await services.storefronts.setAsset(
    operatorId: scope.operatorId,
    kind: kind,
    key: key,
  );

  return _vitrine(services, scope, trace);
}

Future<Response> _remove(
  Services services,
  TenantScope scope,
  BrandAssetKind kind,
  String trace,
) async {
  final vitrine = await services.storefronts.forOperator(scope.operatorId);
  final key = switch (kind) {
    BrandAssetKind.logo => vitrine?.logoAsset,
    BrandAssetKind.cover => vitrine?.coverAsset,
  };

  // The row first this time, and for the mirror of the reason above: clearing
  // the column is what stops the storefront pointing at it, and a delete that
  // succeeded against storage but failed against the database would leave a
  // vitrine referring to a file that is gone.
  await services.storefronts.setAsset(
    operatorId: scope.operatorId,
    kind: kind,
    key: null,
  );
  if (key != null) await services.storage.delete(key);

  return _vitrine(services, scope, trace);
}

Future<Response> _vitrine(
  Services services,
  TenantScope scope,
  String trace,
) async {
  final vitrine = await services.storefronts.forOperator(scope.operatorId);
  if (vitrine == null) {
    return _json(HttpStatus.notFound, Problem.notFound(traceId: trace), trace);
  }

  return _json(
    HttpStatus.ok,
    null,
    trace,
    body: services.withAssetUrls(vitrine).toJson(),
  );
}

/// Each refusal carries the number the operator has to get under, because
/// "too large" without a limit is a sentence somebody guesses at twice.
Response _refused(
  BrandAssetProblem problem,
  BrandAssetKind kind,
  String trace,
) {
  final error = switch (problem) {
    BrandAssetProblem.unsupportedType => ApiError(
      code: ErrorCode.assetUnsupportedType,
      traceId: trace,
    ),
    BrandAssetProblem.tooLarge => ApiError(
      code: ErrorCode.assetTooLarge,
      params: {'maxKb': kind.maxBytes ~/ 1024},
      traceId: trace,
    ),
    BrandAssetProblem.tooWide => ApiError(
      code: ErrorCode.assetTooWide,
      params: {'maxEdge': kind.maxEdge},
      traceId: trace,
    ),
    BrandAssetProblem.unreadable => ApiError(
      code: ErrorCode.assetUnreadable,
      traceId: trace,
    ),
  };

  return _json(Problem.statusFor(error.code), error, trace);
}

Response _json(
  int status,
  ApiError? error,
  String trace, {
  Map<String, Object?>? body,
}) => Response.json(
  statusCode: status,
  body: body ?? error!.toJson(),
  headers: {
    BelHeaders.traceId: trace,
    // Never cached. A vitrine belongs to one tenant and this response carries
    // it whole.
    HttpHeaders.cacheControlHeader: 'private, no-store',
  },
);
