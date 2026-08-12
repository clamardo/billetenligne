import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// The road, as a sequence of places with times.
///
/// Every rule here is load-bearing for something that does not exist yet:
/// segment availability is "is this seat free between position 0 and
/// position 3?", and a list that cannot be ordered has no positions.
void main() {
  Result<Itinerary, InvalidItinerary> build(
    List<RouteStop> stops, {
    int duration = 450,
  }) => Itinerary.of(
    stops,
    originCity: 'BZV',
    destinationCity: 'PNR',
    durationMinutes: duration,
  );

  group('a road with no stops', () {
    test('is a road, not an error', () {
      // Almost every route in this market is one. Refusing the empty case
      // would make the common road the awkward one.
      expect(build(const []).valueOrNull, Itinerary.empty);
      expect(Itinerary.empty.isEmpty, isTrue);
    });

    test('still has two points', () {
      expect(Itinerary.empty.pointsFor(origin: 'BZV', destination: 'PNR'), [
        'BZV',
        'PNR',
      ]);
    });
  });

  group('ordering', () {
    test('is by time, not by the order somebody typed them', () {
      // An operator who remembers Dolisie after typing Nkayi has described
      // the road correctly and typed it out of order. Those are different
      // mistakes and only one of them is theirs.
      final ordered = build(const [
        RouteStop(cityCode: 'DLS', offsetMinutes: 315),
        RouteStop(cityCode: 'MAD', offsetMinutes: 180),
        RouteStop(cityCode: 'KKL', offsetMinutes: 70),
      ]).valueOrNull!;

      expect(ordered.stops.map((s) => s.cityCode), ['KKL', 'MAD', 'DLS']);
    });

    test('two stops at the same minute cannot be ordered, so are refused', () {
      final refused = build(const [
        RouteStop(cityCode: 'MAD', offsetMinutes: 180),
        RouteStop(cityCode: 'DLS', offsetMinutes: 180),
      ]).failureOrNull;

      expect(refused!.reason, 'out_of_order');
    });

    test('the whole sequence is the points a segment indexes into', () {
      final road = build(const [
        RouteStop(cityCode: 'KKL', offsetMinutes: 70),
        RouteStop(cityCode: 'DLS', offsetMinutes: 315),
      ]).valueOrNull!;

      expect(road.pointsFor(origin: 'BZV', destination: 'PNR'), [
        'BZV',
        'KKL',
        'DLS',
        'PNR',
      ]);
    });
  });

  group('what a stop cannot be', () {
    test('an endpoint again', () {
      // "Brazzaville → Pointe-Noire via Brazzaville" is not a road, and the
      // sequence it produces has the same city at two positions — which is
      // exactly what a segment lookup cannot survive.
      final refused = build(const [
        RouteStop(cityCode: 'BZV', offsetMinutes: 60),
      ]).failureOrNull;

      expect(refused!.reason, 'endpoint_repeated');
      expect(refused.params['city'], 'BZV');
    });

    test('the same town twice', () {
      final refused = build(const [
        RouteStop(cityCode: 'DLS', offsetMinutes: 180),
        RouteStop(cityCode: 'DLS', offsetMinutes: 315),
      ]).failureOrNull;

      expect(refused!.reason, 'duplicate_city');
    });

    test('after the coach has arrived', () {
      final refused = build(const [
        RouteStop(cityCode: 'DLS', offsetMinutes: 480),
      ]).failureOrNull;

      expect(refused!.reason, 'after_arrival');
    });

    test('a place nobody gets on or off at', () {
      // A stop that allows neither is a place the coach slows down. It is not
      // a stop, and storing it would put a row in a timetable that no ticket
      // can ever name.
      final refused = build(const [
        RouteStop(
          cityCode: 'DLS',
          offsetMinutes: 315,
          allowsBoarding: false,
          allowsAlighting: false,
        ),
      ]).failureOrNull;

      expect(refused!.reason, 'not_served');
    });
  });

  group('set down only', () {
    test('is a stop, and says so', () {
      // The detail every naive model gets wrong (06-fleet-and-routes.md §4):
      // a yard on the way out of town that people are only ever set down at
      // must not be offerable as a place to get on.
      final road = build(const [
        RouteStop(cityCode: 'NKY', offsetMinutes: 360, allowsBoarding: false),
      ]).valueOrNull!;

      expect(road.stops.single.isServed, isTrue);
      expect(road.stops.single.allowsBoarding, isFalse);
      expect(road.stops.single.allowsAlighting, isTrue);
    });
  });

  group('the failure is a key, never a sentence', () {
    test('so the console can word it in the traveller-facing catalog', () {
      final refused = build(const [
        RouteStop(cityCode: 'DLS', offsetMinutes: 900),
      ]).failureOrNull!;

      expect(refused.code, 'route.invalid_itinerary');
      expect(refused.params, {'reason': 'after_arrival', 'city': 'DLS'});
    });
  });
}
