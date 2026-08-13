import '../shared/failure.dart';
import '../shared/result.dart';
import 'itinerary.dart';

/// Why a piece of a road could not be sold.
final class InvalidSegment extends DomainFailure {
  const InvalidSegment(this.reason, {this.cityCode});

  /// One of `not_on_road`, `same_place`, `wrong_way`, `no_boarding`,
  /// `no_alighting`. A key, never a sentence (ADR-0008).
  final String reason;
  final String? cityCode;

  @override
  String get code => 'segment.invalid';

  @override
  Map<String, Object?> get params => {
    'reason': reason,
    if (cityCode != null) 'city': cityCode,
  };

  @override
  String toString() => 'InvalidSegment($reason, $cityCode)';
}

/// A half-open range of positions on a road (ADR-0025).
///
/// **Half-open, always.** `[0,2)` and `[2,4)` do not overlap, which is the
/// whole point: a passenger alighting at Dolisie and one boarding at Dolisie
/// share no part of the journey, and a closed range would have them fighting
/// over a stop neither of them occupies. The database says the same thing
/// with an exclusion constraint over `INT4RANGE`; this is the same claim in
/// the layer that can explain itself.
///
/// Positions rather than city codes, and that is deliberate: a road that
/// visits the same town twice is unusual and not impossible, and a pair of
/// codes cannot say which visit was meant.
final class Segment {
  const Segment._(this.from, this.to);

  /// Inclusive.
  final int from;

  /// Exclusive.
  final int to;

  int get legs => to - from;

  /// The Postgres literal, so one definition of half-openness serves both
  /// sides rather than two that agree until somebody edits one.
  String get span => '[$from,$to)';

  bool overlaps(Segment other) => from < other.to && other.from < to;

  bool contains(Segment other) => other.from >= from && other.to <= to;

  /// The whole journey, which is what an ordinary sale takes. There is no
  /// special case for it anywhere: a design where the usual case bypasses the
  /// new machinery is a design where the new machinery is untested.
  static Segment wholeRoad(Itinerary itinerary) =>
      Segment._(0, itinerary.stops.length + 1);

  /// Trusted input only — the two ends of a range already validated, or read
  /// back out of the database.
  static Segment at(int from, int to) => Segment._(from, to);

  /// The piece of [itinerary] between two towns, or the reason there is none.
  ///
  /// Boarding and alighting are asked of the stop rather than assumed, which
  /// is the detail every naive model gets wrong and every operator notices in
  /// the first hour: a set-down-only stop can end a segment and cannot start
  /// one.
  static Result<Segment, InvalidSegment> between({
    required Itinerary itinerary,
    required String originCity,
    required String destinationCity,
    required String from,
    required String to,
  }) {
    final points = itinerary.pointsFor(
      origin: originCity,
      destination: destinationCity,
    );

    final start = points.indexOf(from);
    final end = points.indexOf(to);

    if (start < 0) return Err(InvalidSegment('not_on_road', cityCode: from));
    if (end < 0) return Err(InvalidSegment('not_on_road', cityCode: to));
    if (start == end) return Err(InvalidSegment('same_place', cityCode: from));
    // Not an alias for "swap them and carry on": a coach runs one way, and a
    // traveller who typed the towns backwards wants to be told rather than
    // sold the opposite journey.
    if (end < start) return Err(InvalidSegment('wrong_way', cityCode: from));

    if (!_boards(itinerary, start, points.length)) {
      return Err(InvalidSegment('no_boarding', cityCode: from));
    }
    if (!_alights(itinerary, end)) {
      return Err(InvalidSegment('no_alighting', cityCode: to));
    }

    return Ok(Segment._(start, end));
  }

  /// The origin always boards; the destination never does; everything between
  /// is the operator's own answer.
  static bool _boards(Itinerary itinerary, int position, int points) {
    if (position == 0) return true;
    if (position == points - 1) return false;
    return itinerary.stops[position - 1].allowsBoarding;
  }

  static bool _alights(Itinerary itinerary, int position) {
    if (position == 0) return false;
    if (position == itinerary.stops.length + 1) return true;
    return itinerary.stops[position - 1].allowsAlighting;
  }

  @override
  bool operator ==(Object other) =>
      other is Segment && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'Segment($span)';
}
