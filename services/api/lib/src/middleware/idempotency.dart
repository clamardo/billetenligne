import 'dart:convert';

import 'package:bel_contracts/bel_contracts.dart';

/// What the store knows about an idempotency key.
final class IdempotencyRecord {
  const IdempotencyRecord({
    required this.key,
    required this.requestHash,
    this.statusCode,
    this.responseBody,
  });

  final String key;

  /// Hash of the request body. A key reused with a *different* body is almost
  /// always a client bug, and worth failing loudly rather than silently
  /// picking one of the two requests.
  final String requestHash;

  final int? statusCode;
  final Map<String, Object?>? responseBody;

  bool get isComplete => statusCode != null;
}

abstract interface class IdempotencyStore {
  /// Claims the key, or returns the record already there. Must be atomic —
  /// two concurrent taps of the same button race here, and exactly one may
  /// proceed.
  Future<IdempotencyRecord?> claim(
    String key,
    String requestHash,
    String scope,
  );

  Future<void> complete(String key, int statusCode, Map<String, Object?> body);

  /// Releases a claim that failed before producing a response, so the caller
  /// can genuinely retry rather than being told it already happened.
  Future<void> release(String key);
}

/// Outcome of the idempotency check, for the handler to act on.
sealed class IdempotencyOutcome {
  const IdempotencyOutcome();
}

/// First time we have seen this key. Do the work.
final class ProceedFresh extends IdempotencyOutcome {
  const ProceedFresh(this.key);
  final String key;
}

/// Seen before and finished. Return the stored response verbatim.
final class ReplayStored extends IdempotencyOutcome {
  const ReplayStored(this.statusCode, this.body);
  final int statusCode;
  final Map<String, Object?> body;
}

/// Seen before, still running. The client retried before we answered.
final class StillInFlight extends IdempotencyOutcome {
  const StillInFlight();
}

/// Same key, different body.
final class KeyReused extends IdempotencyOutcome {
  const KeyReused();
}

final class MissingKey extends IdempotencyOutcome {
  const MissingKey();
}

/// Idempotency for every request that moves money or inventory.
///
/// This is the single most important safety property in the API: a duplicate
/// tap on a slow connection must never create a second charge or a second
/// hold (ADR-0005 rule 2). It is middleware rather than a per-handler concern
/// precisely so it cannot be forgotten on the one endpoint that matters.
final class Idempotency {
  const Idempotency(this._store);

  final IdempotencyStore _store;

  /// Requests that must carry a key. Anything mutating money or inventory.
  static const requiredFor = <String>{
    'POST /public/v1/holds',
    'POST /public/v1/payments',
    'POST /public/v1/bookings',
    'POST /public/v1/refunds',
    'POST /console/v1/sales',
    'POST /console/v1/refunds',
    'POST /console/v1/disruptions',
  };

  static bool isRequired(String method, String path) =>
      requiredFor.contains('$method $path');

  Future<IdempotencyOutcome> check({
    required String? key,
    required String scope,
    required Object? body,
  }) async {
    if (key == null || key.trim().isEmpty) return const MissingKey();

    final hash = hashBody(body);
    final existing = await _store.claim(key, hash, scope);

    if (existing == null) return ProceedFresh(key);

    if (existing.requestHash != hash) return const KeyReused();

    if (existing.isComplete) {
      return ReplayStored(
        existing.statusCode!,
        existing.responseBody ?? const {},
      );
    }

    return const StillInFlight();
  }

  Future<void> record(String key, int statusCode, Map<String, Object?> body) =>
      _store.complete(key, statusCode, body);

  Future<void> abandon(String key) => _store.release(key);

  /// Stable hash of a request body.
  ///
  /// Keys are sorted so `{a:1,b:2}` and `{b:2,a:1}` hash identically — clients
  /// do not promise key order, and treating a reordered body as a different
  /// request would reject legitimate retries.
  static String hashBody(Object? body) {
    final canonical = _canonicalise(body);
    final text = jsonEncode(canonical);
    // FNV-1a: cheap, dependency-free, and only ever compared for equality.
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(text)) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(16).padLeft(16, '0');
  }

  static Object? _canonicalise(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _canonicalise(value[k])};
    }
    if (value is List) return [for (final v in value) _canonicalise(v)];
    return value;
  }

  /// Maps an outcome to the error a client should see.
  static ApiError? errorFor(IdempotencyOutcome outcome, {String? traceId}) =>
      switch (outcome) {
        MissingKey() => ApiError(
          code: ErrorCode.badRequest,
          params: const {'header': BelHeaders.idempotencyKey},
          fieldErrors: const {
            BelHeaders.idempotencyKey: 'required for this request',
          },
          traceId: traceId,
        ),
        KeyReused() => ApiError(
          code: ErrorCode.idempotencyKeyReused,
          traceId: traceId,
        ),
        // 409, and retryable: the first request is still running, so the
        // honest answer is "ask again shortly", not "it failed".
        StillInFlight() => ApiError(
          code: ErrorCode.conflict,
          retryable: true,
          traceId: traceId,
        ),
        ProceedFresh() || ReplayStored() => null,
      };
}
