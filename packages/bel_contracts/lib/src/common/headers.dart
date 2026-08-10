/// Header and query-parameter names, in one place so client and server cannot
/// disagree about a spelling.
final class BelHeaders {
  const BelHeaders._();

  /// Required on every POST that moves money or inventory. The client
  /// generates a UUID v4 per attempt and reuses it across retries.
  static const idempotencyKey = 'Idempotency-Key';

  /// Set on a response the server recognised as a replay. Useful in support:
  /// it distinguishes "charged twice" from "asked twice, charged once".
  static const idempotencyReplayed = 'Idempotency-Replayed';

  /// Correlates a user-visible failure with the server log.
  static const traceId = 'X-Trace-Id';

  /// The reader's language, so the server renders SMS and PDFs correctly.
  /// Falls back to the account's stored preference, then to French.
  static const language = 'X-Language';

  /// Which market the client believes it is in. Advisory — the server
  /// resolves authoritatively from the account.
  static const market = 'X-Market';

  /// Why one of our own people is reaching across a tenant boundary.
  ///
  /// Required on every write to `/admin/v1` and recorded on every read
  /// (ADR-0011). It lives here rather than only in the server so that the
  /// back office and the middleware cannot disagree about its spelling — a
  /// disagreement whose symptom is a 400 nobody can explain.
  static const reason = 'X-Bel-Reason';

  static const appVersion = 'X-App-Version';
  static const deviceId = 'X-Device-Id';
}

/// Conditional-request support. A 304 costs about 200 bytes, which on a
/// metered prepaid bundle is a feature rather than a micro-optimisation
/// (ADR-0003).
final class CacheHeaders {
  const CacheHeaders._();
  static const etag = 'ETag';
  static const ifNoneMatch = 'If-None-Match';
}
