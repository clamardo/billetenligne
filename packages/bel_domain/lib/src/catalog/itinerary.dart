import 'package:bel_platform/bel_platform.dart';

/// One intermediate stop on a road.
///
/// [offsetMinutes] is measured from the departure, not from the previous
/// stop, because that is the number a dispatcher can check against a timetable
/// they already have: "Dolisie, cinq heures quinze" is a fact about the whole
/// journey, whereas "two hours ten after Madingou" is arithmetic somebody has
/// to do before they can tell whether it is right.
///
/// The two flags are the detail every naive model gets wrong and every
/// operator notices immediately (`06-fleet-and-routes.md` §4). A yard on the
/// way out of Brazzaville that people are only ever set down at must not be
/// offerable as a place to get on.
final class RouteStop {
  const RouteStop({
    required this.cityCode,
    required this.offsetMinutes,
    this.stationId,
    this.allowsBoarding = true,
    this.allowsAlighting = true,
  });

  final String cityCode;
  final int offsetMinutes;

  /// Which yard, when the operator has named one. Optional in a way the
  /// endpoints are not: a coach that pauses at a roadside town may have no
  /// terminal there at all, and inventing one would put an address on a
  /// ticket that nobody can find.
  final String? stationId;

  final bool allowsBoarding;
  final bool allowsAlighting;

  /// A stop that is neither is not a stop. Kept as a question rather than a
  /// constructor assertion because the console asks it of a half-filled form
  /// on every keystroke.
  bool get isServed => allowsBoarding || allowsAlighting;
}

/// Why an ordered list of stops was refused.
final class InvalidItinerary extends DomainFailure {
  const InvalidItinerary(this.reason, {this.cityCode});

  /// One of `out_of_order`, `duplicate_city`, `endpoint_repeated`,
  /// `after_arrival`, `not_served`. A key, never a sentence (ADR-0008).
  final String reason;
  final String? cityCode;

  @override
  String get code => 'route.invalid_itinerary';

  @override
  Map<String, Object?> get params => {
    'reason': reason,
    if (cityCode != null) 'city': cityCode,
  };

  @override
  String toString() => 'InvalidItinerary($reason, $cityCode)';
}

/// The road, as a sequence of places with times.
///
/// **Ordering is a rule, not a presentation choice.** A stop list out of
/// order is not a cosmetic problem: it is what a segment's availability will
/// be computed from, and "is this seat free between Brazzaville and Dolisie?"
/// is a question about positions in a sequence. Checking it once, here, is
/// what lets every later query trust `sequence`.
///
/// Sequences are **assigned rather than accepted**. An operator drags a row
/// up a list; asking them to renumber four rows afterwards is asking them to
/// do the computer's job, and getting it wrong is a silent data error rather
/// than a visible one.
final class Itinerary {
  const Itinerary._(this.stops);

  /// In order, from the first one after the origin.
  final List<RouteStop> stops;

  static const empty = Itinerary._([]);

  bool get isEmpty => stops.isEmpty;

  /// Every place a coach touches, endpoints included, in order. This is the
  /// sequence a segment is a pair of indices into.
  List<String> pointsFor({
    required String origin,
    required String destination,
  }) => [origin, for (final stop in stops) stop.cityCode, destination];

  /// Validates and orders. The list is sorted by time here rather than
  /// trusted, so an operator who added Dolisie before Madingou and set the
  /// times correctly gets the road they described rather than an error about
  /// the order they typed it in.
  static Result<Itinerary, InvalidItinerary> of(
    List<RouteStop> stops, {
    required String originCity,
    required String destinationCity,
    required int durationMinutes,
  }) {
    if (stops.isEmpty) return const Ok(empty);

    final ordered = [...stops]
      ..sort((a, b) => a.offsetMinutes.compareTo(b.offsetMinutes));

    final seen = <String>{};
    var previous = 0;

    for (final stop in ordered) {
      if (stop.cityCode == originCity || stop.cityCode == destinationCity) {
        return Err(
          InvalidItinerary('endpoint_repeated', cityCode: stop.cityCode),
        );
      }
      if (!seen.add(stop.cityCode)) {
        return Err(InvalidItinerary('duplicate_city', cityCode: stop.cityCode));
      }
      // Two stops at the same minute cannot be ordered, and an order is
      // exactly what the rest of the system will read off this list.
      if (stop.offsetMinutes <= previous) {
        return Err(InvalidItinerary('out_of_order', cityCode: stop.cityCode));
      }
      if (stop.offsetMinutes >= durationMinutes) {
        return Err(InvalidItinerary('after_arrival', cityCode: stop.cityCode));
      }
      if (!stop.isServed) {
        return Err(InvalidItinerary('not_served', cityCode: stop.cityCode));
      }
      previous = stop.offsetMinutes;
    }

    return Ok(Itinerary._(ordered));
  }
}
