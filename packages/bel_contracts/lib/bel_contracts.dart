/// The BilletEnLigne wire format, defined once.
///
/// Serialised by the Dart Frog API and parsed by the traveller app, the
/// operator console and the admin back office. Adding a field is one edit
/// here and every end fails to compile until updated — which is the good kind
/// of breakage (ADR-0004).
///
/// Two rules run through all of it:
///
///  * **Money is `{minor, currency}`** — never a float, never a pre-formatted
///    string. Formatting belongs to the surface that renders it.
///  * **The server never sends prose.** Errors and labels travel as catalog
///    keys plus parameters, so a French traveller never receives an English
///    sentence (ADR-0008).
library;

export 'src/admin/admin_dto.dart';
export 'src/admin/funnel_dto.dart';
export 'src/admin/operator_lifecycle.dart';
export 'src/admin/reconciliation_dto.dart';
export 'src/auth/auth_dto.dart';
export 'src/booking/booking_dto.dart';
export 'src/booking/cancellation_dto.dart';
export 'src/booking/change_dto.dart';
export 'src/booking/missed_dto.dart';
export 'src/catalog/city_dto.dart';
export 'src/catalog/seat_map_dto.dart';
export 'src/catalog/station_dto.dart';
export 'src/catalog/trip_dto.dart';
export 'src/catalog/vitrine_dto.dart';
export 'src/common/headers.dart';
export 'src/common/page.dart';
export 'src/config/market_dto.dart';
export 'src/console/console_dto.dart';
export 'src/console/layout_draft.dart';
export 'src/console/refund_dto.dart';
export 'src/console/refund_policy_dto.dart';
export 'src/disruption/disruption_dto.dart';
export 'src/disruption/protection_dto.dart';
export 'src/disruption/choice_dto.dart';
export 'src/trip/trip_share_dto.dart';
export 'src/onboarding/application_dto.dart';
export 'src/error/api_error.dart';
export 'src/error/error_code.dart';
export 'src/json/json_codec.dart';
export 'src/payment/payment_dto.dart';
export 'src/payout/payout_dto.dart';
