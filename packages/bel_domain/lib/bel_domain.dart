/// BilletEnLigne domain core — pure Dart, zero dependencies.
///
/// Compiled into the Flutter apps **and** the Dart server so every rule about
/// money, policy and inventory is implemented exactly once (ADR-0001,
/// ADR-0004). If it can be decided without a screen or a database, it lives
/// here.
library;

export 'src/shared/result.dart';
export 'src/shared/failure.dart';
export 'src/shared/clock.dart';
export 'src/money/currency.dart';
export 'src/money/ledger.dart';
export 'src/money/money.dart';
export 'src/identity/email_address.dart';
export 'src/identity/phone_number.dart';
export 'src/market/market.dart';
export 'src/market/payment_rail.dart';
export 'src/booking/booking_ref.dart';
export 'src/booking/hold.dart';
export 'src/payment/payment_intent.dart';
export 'src/ticketing/crypto_ports.dart';
export 'src/ticketing/rotating_code.dart';
export 'src/ticketing/ticket_payload.dart';
export 'src/ticketing/verification.dart';
export 'src/catalog/transport_mode.dart';
export 'src/catalog/seat_layout.dart';
export 'src/policy/refund_policy.dart';
