/// The BilletEnLigne API, typed.
///
/// Compiled unchanged into the traveller app, the operator console and the
/// admin back office. One place that knows about retries, idempotency keys,
/// trace ids and what "offline" means — so three surfaces cannot invent three
/// different answers to the same bad connection (ADR-0004).
library;

export 'src/api_failure.dart';
export 'src/bel_api_client.dart';
export 'src/idempotency_key.dart';
export 'src/retry_policy.dart';
