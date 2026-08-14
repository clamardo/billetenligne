/// BilletEnLigne transport domain — pure Dart, one dependency.
///
/// Departures, routes, cabin sections and `TransportMode`; holds, booking
/// references, refund and change policy; tickets, boarding and verification;
/// disruption, protection and segments. Compiled into the Flutter apps **and**
/// the Dart Frog server so every rule is implemented exactly once (ADR-0001,
/// ADR-0004).
///
/// It keeps its name. Renaming it to `bel_transport` would touch all 263
/// consumer files to say something the dependency graph already says
/// (ADR-0027 §1).
///
/// What it may not import: `bel_rental`, `bel_stay`, `bel_reviews`. The
/// verticals share the platform beneath them and nothing above the booking,
/// and one import is that decision undone.
library;

// ── TRANSITIONAL. Removed by P2b (`15-platform-split.md` §6). ──────────────
//
// Every consumer that imports this package for a platform type keeps
// compiling while the move lands, so P2a can be reviewed as a file move
// rather than as two hundred import edits.
//
// It is legal — bel_domain → bel_platform is the allowed direction — and it
// is still wrong to keep. A re-export hides where a type lives, and a reader
// cannot tell whether `Money` is transport's or the platform's. In three
// months two more packages will be asking that question.
export 'package:bel_platform/bel_platform.dart';
// ──────────────────────────────────────────────────────────────────────────

export 'src/booking/booking_ref.dart';
export 'src/booking/hold.dart';
export 'src/booking/cancellation.dart';
export 'src/catalog/transport_mode.dart';
export 'src/catalog/seat_layout.dart';
export 'src/catalog/itinerary.dart';
export 'src/catalog/segment.dart';
export 'src/catalog/recurrence.dart';
export 'src/policy/refund_policy.dart';
export 'src/policy/change_policy.dart';
export 'src/ticketing/rotating_code.dart';
export 'src/ticketing/ticket_payload.dart';
export 'src/ticketing/verification.dart';
export 'src/disruption/disruption.dart';
export 'src/disruption/protection.dart';
export 'src/disruption/reaccommodation.dart';
export 'src/disruption/self_service.dart';
export 'src/disruption/seat_remap.dart';
export 'src/trip/trip_share.dart';
