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
}
