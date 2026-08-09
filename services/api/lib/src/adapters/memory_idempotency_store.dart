import '../middleware/idempotency.dart';

/// In-memory idempotency store for tests and local development.
///
/// Production uses the `idempotency_keys` table, where `claim` is a single
/// `INSERT ... ON CONFLICT DO NOTHING RETURNING` — atomic in one round trip,
/// which is what makes two concurrent taps race correctly. This fake matches
/// that contract exactly, so the tests written against it stay meaningful.
final class MemoryIdempotencyStore implements IdempotencyStore {
  final Map<String, IdempotencyRecord> _records = {};

  @override
  Future<IdempotencyRecord?> claim(
    String key,
    String requestHash,
    String scope,
  ) async {
    final existing = _records[key];
    if (existing != null) return existing;
    _records[key] = IdempotencyRecord(key: key, requestHash: requestHash);
    return null;
  }

  @override
  Future<void> complete(
    String key,
    int statusCode,
    Map<String, Object?> body,
  ) async {
    final existing = _records[key];
    if (existing == null) return;
    _records[key] = IdempotencyRecord(
      key: key,
      requestHash: existing.requestHash,
      statusCode: statusCode,
      responseBody: body,
    );
  }

  @override
  Future<void> release(String key) async => _records.remove(key);

  int get size => _records.length;
}
