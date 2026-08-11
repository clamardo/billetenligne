import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

/// Everything the traveller journey needs from the outside world.
///
/// One port, not four, because these four calls are one conversation: search
/// leads to a seat map leads to a hold leads to releasing it. Splitting them
/// would mean four fakes to keep consistent in every test, and the moment two
/// of those fakes disagree the tests stop meaning anything.
///
/// The HTTP client sits behind this rather than being used directly by
/// screens: a screen that constructs a request cannot be tested without a
/// server, and cannot be reused by the console.
abstract interface class TravelGateway {
  /// Where you can go. The first call the app makes, because the search
  /// screen cannot render a picker without it.
  Future<List<CityDto>> cities();

  Future<List<DepartureSummaryDto>> search(SearchDeparturesQuery query);

  Future<SeatMapDto> seatMap(String departureId);

  /// Claims seats.
  ///
  /// [idempotencyKey] is supplied by the caller so that a retry of a *lost*
  /// attempt carries the key of that attempt. Generating a fresh one on retry
  /// is how a dropped connection turns into two holds on two different seats.
  Future<HoldDto> hold({
    required String departureId,
    required List<String> seatLabels,
    required String idempotencyKey,
  });

  Future<void> release(String holdId);

  /// Turns a hold into an unpaid reservation with a code to pay at an agency.
  ///
  /// No price is sent. The fare is read from the seat row inside the
  /// transaction that consumes the hold, which is what removes the window
  /// between quoting a price and charging it.
  Future<BookingDto> reserve({
    required String holdId,
    required List<PassengerDto> passengers,
    required String idempotencyKey,
  });

  /// One booking, refreshed.
  Future<BookingDto> booking(String bookingId);

  /// Everything this traveller has bought, newest first — paid or not.
  ///
  /// The tickets travel inside it, QR payload and all, so opening a ticket
  /// costs no second request. That is the point: this is the screen somebody
  /// opens at a coach door with one bar of signal, and a list that needs a
  /// follow-up call per ticket is a list that fails exactly there.
  Future<List<BookingDto>> bookings();

  // ── When the coach does not go ────────────────────────────────────────────

  /// What this passenger may do about a disrupted journey
  /// (`08-disruption.md` §3.2).
  ///
  /// Fetched when the screen opens and never held: the seat counts on the
  /// alternatives are the point, and a stale one offers a coach that filled.
  Future<TravelChoicesDto> travelOptions(String bookingRef);

  /// Take one. The movement happens inside this call — seats taken before the
  /// old ones are released, ticket re-signed — so there is nothing left to do
  /// afterwards and nothing to forget.
  Future<ChoiceAppliedDto> chooseTravel({
    required String bookingRef,
    required String optionId,
  });

  // ── Sharing a trip ────────────────────────────────────────────────────────

  /// Mints the link, or hands back the one that already exists (ADR-0014 §2).
  Future<TripShareDto> shareTrip(String bookingRef);

  /// Their own view of it. Null when they have never shared this booking —
  /// which is not an error and must not arrive on a screen as one.
  Future<TripShareDto?> tripShare(String bookingRef);

  Future<void> revokeTripShare(String bookingRef);

  // ── Changing their mind ───────────────────────────────────────────────────

  /// What cancelling this booking would do (§8.2).
  ///
  /// Always read before the button is drawn. The common case is a reservation
  /// nobody paid for, where "refund" is the wrong word entirely, and only the
  /// server knows which case this is.
  Future<CancellationOfferDto> cancellationOffer(String bookingRef);

  /// Does it. The seat is on sale again before this returns.
  Future<CancellationDoneDto> cancelBooking(String bookingRef);

  /// Where else this booking could go, priced on every row (§8.1).
  Future<ChangeOptionsDto> changeOptions(String bookingRef);

  /// Moves them. Seats taken, old ones released, ticket re-signed, in one
  /// call.
  Future<ChangeAppliedDto> changeDeparture({
    required String bookingRef,
    required String departureId,
  });

  /// Holds a change that owes money, and says exactly what.
  ///
  /// Nothing moves. The seats are held for the length of the payment window
  /// and the booking stays where it is until the difference is captured — so
  /// a screen must never say "changed" on the strength of this answer.
  Future<ChangeOrderDto> orderChange({
    required String bookingRef,
    required String departureId,
  });

  // ── Paying ────────────────────────────────────────────────────────────────

  /// How this booking can be paid, and where the money goes.
  ///
  /// Server-driven, so enabling a rail is a config push rather than an app
  /// release (ADR-0006). Carries the traveller's own number so the payer
  /// field can be prefilled, and the amount so the confirmation screen does
  /// not have to recompute one.
  Future<
    ({List<PaymentOptionDto> options, String? accountMsisdn, Money amount})
  >
  paymentOptions(String bookingId, {String? changeId});

  /// Pushes a PIN prompt to a handset. Answers `pending`, never `paid`.
  Future<PaymentIntentDto> startPayment({
    required String bookingId,
    required String railId,
    required String payerMsisdn,
    required String idempotencyKey,
    String? changeId,
  });

  Future<PaymentIntentDto> paymentStatus(String intentId);
}
