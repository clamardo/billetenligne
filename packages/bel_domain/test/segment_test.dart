import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// A piece of a road (ADR-0025).
///
/// The half-open rule is the whole file: `[0,2)` and `[2,4)` do not overlap,
/// which is what lets one passenger alight at Dolisie and another board
/// there on the same seat. Everything else here is a rule an operator will
/// notice within an hour of it being wrong.
void main() {
  /// Brazzaville → Dolisie → Madingou → Pointe-Noire, with Madingou
  /// set-down-only: the coach stops there and nobody gets on.
  final road = Itinerary.of(
    const [
      RouteStop(cityCode: 'DOL', offsetMinutes: 180),
      RouteStop(cityCode: 'MDG', offsetMinutes: 300, allowsBoarding: false),
    ],
    originCity: 'BZV',
    destinationCity: 'PNR',
    durationMinutes: 450,
  ).valueOrNull!;

  Result<Segment, InvalidSegment> between(String from, String to) =>
      Segment.between(
        itinerary: road,
        originCity: 'BZV',
        destinationCity: 'PNR',
        from: from,
        to: to,
      );

  group('positions on a road', () {
    test('the whole journey is a range like any other', () {
      // No special case anywhere for the commonest sale, on purpose: a design
      // where the usual case skips the new machinery is one where the new
      // machinery is untested in production.
      expect(Segment.wholeRoad(road), Segment.at(0, 3));
      expect(between('BZV', 'PNR').valueOrNull, Segment.wholeRoad(road));
    });

    test('a road with no stops is one leg', () {
      expect(Segment.wholeRoad(Itinerary.empty), Segment.at(0, 1));
      expect(Segment.wholeRoad(Itinerary.empty).span, '[0,1)');
    });

    test('a piece of it is a pair of positions, not a pair of names', () {
      expect(between('BZV', 'DOL').valueOrNull, Segment.at(0, 1));
      expect(between('DOL', 'PNR').valueOrNull, Segment.at(1, 3));
      expect(between('DOL', 'MDG').valueOrNull!.span, '[1,2)');
    });
  });

  group('half-open is the point', () {
    test('two passengers can share a seat at a town', () {
      final first = between('BZV', 'DOL').valueOrNull!;
      final second = between('DOL', 'PNR').valueOrNull!;

      // She alights at Dolisie, he boards there. A closed range would have
      // them fighting over a stop neither of them occupies.
      expect(first.overlaps(second), isFalse);
      expect(second.overlaps(first), isFalse);
    });

    test('and cannot share one anywhere else', () {
      final through = Segment.wholeRoad(road);
      expect(through.overlaps(between('DOL', 'MDG').valueOrNull!), isTrue);
      expect(
        between(
          'BZV',
          'MDG',
        ).valueOrNull!.overlaps(between('DOL', 'PNR').valueOrNull!),
        isTrue,
      );
    });

    test('a leg is inside the journey that covers it', () {
      expect(
        Segment.wholeRoad(road).contains(between('DOL', 'MDG').valueOrNull!),
        isTrue,
      );
      expect(
        between('BZV', 'DOL').valueOrNull!.contains(Segment.wholeRoad(road)),
        isFalse,
      );
    });
  });

  group('what cannot be sold', () {
    test('a town the coach never passes', () {
      final refused = between('BZV', 'OWA').failureOrNull!;
      expect(refused.reason, 'not_on_road');
      expect(refused.cityCode, 'OWA');
      // A key, not a sentence: the console and the app say this in their own
      // words and their own language (ADR-0008).
      expect(refused.code, 'segment.invalid');
    });

    test('a journey from a place to itself', () {
      expect(between('DOL', 'DOL').failureOrNull!.reason, 'same_place');
    });

    test('a journey the coach runs the other way', () {
      // Not silently swapped. A traveller who typed the towns backwards wants
      // to be told, not sold the opposite journey.
      expect(between('PNR', 'BZV').failureOrNull!.reason, 'wrong_way');
      expect(between('MDG', 'DOL').failureOrNull!.reason, 'wrong_way');
    });

    test('boarding where the operator only sets down', () {
      // The detail every naive model gets wrong. Madingou can end a journey
      // and cannot start one.
      expect(between('MDG', 'PNR').failureOrNull!.reason, 'no_boarding');
      expect(between('DOL', 'MDG').valueOrNull, isNotNull);
    });

    test('boarding at the destination, or alighting at the origin', () {
      // Neither is a stop somebody can use in that direction, and both are
      // reachable from a form with two dropdowns.
      expect(between('PNR', 'PNR').failureOrNull!.reason, 'same_place');
      expect(
        Segment.between(
          itinerary: road,
          originCity: 'BZV',
          destinationCity: 'PNR',
          from: 'PNR',
          to: 'DOL',
        ).failureOrNull!.reason,
        'wrong_way',
      );
    });
  });

  test('the span is written once, for both sides of the wire', () {
    // The database says half-open with an INT4RANGE and an exclusion
    // constraint; this is the same claim in the layer that can explain
    // itself, and the literal is generated rather than typed twice.
    expect(Segment.at(0, 1).span, '[0,1)');
    expect(Segment.at(2, 5).span, '[2,5)');
    expect(Segment.at(2, 5).legs, 3);
  });

  group('what an operator has priced', () {
    Result<SegmentPricing, InvalidSegment> price(
      List<({String from, String to, Money fare})> asked,
    ) => SegmentPricing.of(
      asked,
      itinerary: road,
      originCity: 'BZV',
      destinationCity: 'PNR',
    );

    test('nothing priced is the ordinary case, not an absence of data', () {
      // Which is what makes the whole model shippable: until this list has
      // something in it, every departure sells its whole road for its whole
      // fare exactly as it always has.
      expect(price(const []).valueOrNull, SegmentPricing.empty);
      expect(SegmentPricing.empty.isEmpty, isTrue);
    });

    test('a priced leg can be looked up by the piece it covers', () {
      final list = price(const [
        (from: 'BZV', to: 'DOL', fare: Money.xaf(6000)),
        (from: 'DOL', to: 'PNR', fare: Money.xaf(7000)),
      ]).valueOrNull!;

      expect(list.fareFor(Segment.at(0, 1)), const Money.xaf(6000));
      expect(list.fareFor(Segment.at(1, 3)), const Money.xaf(7000));
      // Not priced is not zero, and the difference is whether it is on sale.
      expect(list.fareFor(Segment.at(0, 2)), isNull);
    });

    test('the list comes back in road order, whatever order it was typed', () {
      final list = price(const [
        (from: 'DOL', to: 'PNR', fare: Money.xaf(7000)),
        (from: 'BZV', to: 'MDG', fare: Money.xaf(9000)),
        (from: 'BZV', to: 'DOL', fare: Money.xaf(6000)),
      ]).valueOrNull!;

      expect(
        [for (final p in list.prices) p.segment.span],
        ['[0,1)', '[0,2)', '[1,3)'],
      );
    });

    test(
      'the whole road is refused, because the timetable already prices it',
      () {
        // Two places to set one price is one place too many, and the day they
        // disagree a traveller is quoted one and charged the other.
        final refused = price(const [
          (from: 'BZV', to: 'PNR', fare: Money.xaf(12000)),
        ]).failureOrNull!;
        expect(refused.reason, 'whole_road');
      },
    );

    test('the same piece cannot carry two prices', () {
      final refused = price(const [
        (from: 'BZV', to: 'DOL', fare: Money.xaf(6000)),
        (from: 'BZV', to: 'DOL', fare: Money.xaf(6500)),
      ]).failureOrNull!;
      expect(refused.reason, 'already_priced');
    });

    test('a free seat is a mistake, not a price', () {
      // Caught here, where the person who typed it is standing, rather than
      // by the ledger three tables downstream.
      expect(
        price(const [
          (from: 'BZV', to: 'DOL', fare: Money.xaf(0)),
        ]).failureOrNull!.reason,
        'not_positive',
      );
    });

    test('and a piece nobody can board is still refused when priced', () {
      // Pricing does not override the road. Madingou sets down only.
      final refused = price(const [
        (from: 'MDG', to: 'PNR', fare: Money.xaf(4000)),
      ]).failureOrNull!;
      expect(refused.reason, 'no_boarding');
      expect(refused.cityCode, 'MDG');
    });
  });
}
