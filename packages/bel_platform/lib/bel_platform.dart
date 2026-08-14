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
/// A type belongs here only if **at least two verticals need it and neither
/// owns it**. Three that look like they belong and do not — `BookingRef`,
/// `HoldPolicy` and `RefundDestination` — are named in `15-platform-split.md`
/// §3.1 with the trigger that moves each one. Today a single vertical needs
/// all three, so all three stayed put.
library;

export 'src/shared/result.dart';
export 'src/shared/failure.dart';
export 'src/shared/clock.dart';
export 'src/money/currency.dart';
export 'src/money/money.dart';
export 'src/money/commission.dart';
export 'src/money/ledger.dart';
export 'src/money/payout.dart';
export 'src/identity/email_address.dart';
export 'src/identity/phone_number.dart';
export 'src/identity/totp.dart';
export 'src/market/market.dart';
export 'src/market/payment_rail.dart';
export 'src/payment/payment_intent.dart';
// Named for inventory, defined by the payment window, and beside
// PaymentIntent because `indeterminateAfter` is stated relative to it.
export 'src/payment/hold_policy.dart';
export 'src/branding/brand_asset.dart';
export 'src/operator/operator_application.dart';
export 'src/operator/document_expiry.dart';
export 'src/operator/onboarding_risk.dart';
// Filed under `ticketing/` until this split, because ticketing was its first
// caller. It is four interfaces over Ed25519 and HMAC and it was never about
// tickets — `identity/totp.dart` needs it too, which is what forced the move:
// a platform file importing a transport-filed one is the illegal direction,
// and it is the ONLY such edge the whole split had to decide
// (`15-platform-split.md` §1.2).
export 'src/crypto/crypto_ports.dart';
