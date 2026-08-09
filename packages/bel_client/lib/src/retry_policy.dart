/// How hard to try again, and how long to wait.
///
/// Tuned for the network this app actually runs on. A Congolese 2G connection
/// drops requests routinely and comes back within seconds — so retrying is
/// nearly always right, and retrying *immediately* is nearly always wrong,
/// because the radio is usually still renegotiating.
///
/// Jitter is not decoration. Without it, every handset that lost signal in the
/// same tunnel retries in the same millisecond when it comes out, and we build
/// our own thundering herd.
final class RetryPolicy {
  const RetryPolicy({
    required this.maxAttempts,
    required this.initialDelay,
    this.multiplier = 2.0,
    this.maxDelay = const Duration(seconds: 8),
    this.jitter = 0.25,
  });

  /// Retries *after* the first try, so 2 means up to three requests.
  final int maxAttempts;

  final Duration initialDelay;
  final double multiplier;
  final Duration maxDelay;

  /// Fraction of the delay to spread randomly, in [0, 1].
  final double jitter;

  static const standard = RetryPolicy(
    maxAttempts: 2,
    initialDelay: Duration(milliseconds: 400),
  );

  /// For tests and for the one screen where waiting is worse than failing.
  static const none = RetryPolicy(
    maxAttempts: 0,
    initialDelay: Duration.zero,
    jitter: 0,
  );

  Duration delayFor(int attempt) {
    var ms = initialDelay.inMilliseconds.toDouble();
    for (var i = 1; i < attempt; i++) {
      ms *= multiplier;
    }
    ms = ms.clamp(0, maxDelay.inMilliseconds.toDouble());

    if (jitter <= 0) return Duration(milliseconds: ms.round());

    // Deterministic spread rather than Random(): a client is constructed once
    // and this must be reproducible in a test. The attempt number and the
    // delay are enough to scatter handsets that lost signal together.
    final spread = ms * jitter;
    final offset = ((attempt * 2654435761) % 1000) / 1000.0;
    return Duration(milliseconds: (ms - spread / 2 + spread * offset).round());
  }
}
