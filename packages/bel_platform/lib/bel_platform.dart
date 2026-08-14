/// BilletEnLigne platform core — pure Dart, zero dependencies.
///
/// The floor under every vertical (ADR-0027). Money, currency, commission,
/// the ledger and payouts; market configuration and payment rails; email,
/// phone and TOTP; the payment intent; operator applications, document expiry
/// and onboarding risk; brand assets; the crypto ports; `Result`,
/// `DomainFailure` and `Clock`.
///
/// It knows nothing about seats, rooms or cars, and `tool/check_layers.dart`
/// keeps it that way: the moment this package imports a vertical, adding the
/// next vertical means changing the floor.
///
/// **This library is deliberately empty.** `15-platform-split.md` §4 ships the
/// package before it ships its contents, so that the workspace plumbing — ten
/// pubspecs, the pub workspace list, four Flutter apps resolving a new path
/// dependency — is proved green on its own, before nineteen files start
/// moving through it in P2a. An empty package that CI is happy with is a
/// smaller thing to debug than a half-moved domain.
library;

// Contents arrive in P2a, moved from `bel_domain` (15-platform-split.md §3).
// The nineteen exports are listed there, in the order they will appear here.
