import 'package:bel_contracts/bel_contracts.dart';

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
}
