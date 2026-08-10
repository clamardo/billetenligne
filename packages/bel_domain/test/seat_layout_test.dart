import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  _abreastGuards();
  group('CabinSection', () {
    test('parses an abreast configuration into blocks', () {
      const section = CabinSection(
        code: 'Y',
        labelKey: 'seat.class.economy',
        rows: 10,
        abreast: '2+3',
      );
      expect(section.blocks, [2, 3]);
      expect(section.seatsPerRow, 5);
      expect(section.capacity, 50);
    });

    test('labels seats with row+letter, skipping I', () {
      const section = CabinSection(
        code: 'F',
        labelKey: 'seat.class.first',
        rows: 2,
        abreast: '2+3',
      );
      expect(section.seatLabels(), [
        '1A',
        '1B',
        '1C',
        '1D',
        '1E',
        '2A',
        '2B',
        '2C',
        '2D',
        '2E',
      ]);
    });

    test('honours a start row so sections stack correctly', () {
      const section = CabinSection(
        code: 'Y',
        labelKey: 'seat.class.economy',
        rows: 2,
        abreast: '2+2',
        startRow: 4,
      );
      expect(section.seatLabels().first, '4A');
      expect(section.seatLabels().last, '5D');
    });

    test('supports sequential numbering with an offset', () {
      const section = CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: 2,
        abreast: '2+2',
        numbering: SeatNumbering.sequential,
      );
      expect(section.seatLabels(sequentialOffset: 10).first, '11');
      expect(section.seatLabels(sequentialOffset: 10).last, '18');
    });
  });

  group('SeatLayout — one model for coaches and aircraft (ADR-0017)', () {
    test('the brief\'s aircraft: 3 rows of 5 first, 10 rows of 5 economy', () {
      final layout = SeatLayout.airTwoClass();

      expect(layout.mode, TransportMode.air);
      expect(layout.sections.length, 2);
      expect(layout.sections[0].capacity, 15);
      expect(layout.sections[1].capacity, 50);
      expect(layout.grossCapacity, 65);
      expect(layout.capacity, 65);
    });

    test('sections do not collide in labelling', () {
      final layout = SeatLayout.airTwoClass();
      final labels = layout.allSeatLabels();
      expect(
        labels.length,
        labels.toSet().length,
        reason: 'seat labels must be unique across sections',
      );
      expect(labels.first, '1A');
      expect(labels.last, '13E');
    });

    test('a seat resolves back to its section, so pricing knows its class', () {
      final layout = SeatLayout.airTwoClass();
      expect(layout.sectionForSeat('1A')!.code, 'F');
      expect(layout.sectionForSeat('13E')!.code, 'Y');
      expect(layout.sectionForSeat('99Z'), isNull);
    });

    test('the VIP-front coach is just two sections — no special case', () {
      final layout = SeatLayout.busVipFront();
      expect(layout.mode, TransportMode.bus);
      expect(layout.sections[0].code, 'VIP');
      expect(layout.sections[0].capacity, 9); // 3 rows of 1+2
      expect(layout.sections[1].capacity, 40); // 10 rows of 2+2
      expect(layout.capacity, 49);
    });

    test('the 5-across rear bench is a one-row section', () {
      final layout = SeatLayout.busStandard49();
      expect(layout.sections.last.rows, 1);
      expect(layout.sections.last.seatsPerRow, 5);
      expect(layout.capacity, 49); // 11 rows of 4, plus the bench
    });

    test('blocked seats reduce sellable capacity but keep the grid intact', () {
      final base = SeatLayout.busStandard49();
      final withBlocked = SeatLayout(
        version: base.version,
        mode: base.mode,
        sections: base.sections,
        blocked: const {'7C', '7D'},
      );
      expect(withBlocked.grossCapacity, 49);
      expect(withBlocked.capacity, 47);
    });
  });
}

void _abreastGuards() {
  group('the 2+3 notation, and what it refuses', () {
    // Every one of these arrives from an operator's console over HTTP, and
    // every one of them used to get through.
    test('a typo is a refusal, not an exception', () {
      expect(Abreast.parse('abc'), isNull);
      expect(Abreast.parse(''), isNull);
      expect(Abreast.parse('  '), isNull);
      expect(Abreast.parse('2++2'), isNull);
    });

    test('a negative block cannot shrink a layout', () {
      expect(Abreast.parse('-4+2'), isNull);
      expect(Abreast.parse('0+2'), isNull);
    });

    // Ten is the width of the letter table, and also wider than anything that
    // carries passengers: a 3+4+3 widebody is exactly ten.
    test('a row wider than the letter table is refused', () {
      expect(Abreast.parse('3+4+3'), [3, 4, 3]);
      expect(Abreast.parse('9+9'), isNull);
      expect(Abreast.parse('11'), isNull);
    });

    test('more than three aisles is refused', () {
      expect(Abreast.parse('1+1+1+1'), [1, 1, 1, 1]);
      expect(Abreast.parse('1+1+1+1+1'), isNull);
    });

    test('whitespace around the numbers is forgiven', () {
      expect(Abreast.parse(' 2 + 3 '), [2, 3]);
    });
  });

  group('a section that cannot be drawn has no seats', () {
    // Nothing downstream throws. The edge that accepted it is what should
    // have refused it, and `isValid` is how it knows to.
    test('and says so, rather than throwing out of a getter', () {
      const broken = CabinSection(
        code: 'X',
        labelKey: 'seat.class.standard',
        rows: 2,
        abreast: 'abc',
      );

      expect(broken.isValid, isFalse);
      expect(broken.capacity, 0);
      expect(broken.seatLabels(), isEmpty);
    });

    test('a layout with no sections is not valid either', () {
      const empty = SeatLayout(
        version: 1,
        mode: TransportMode.bus,
        sections: [],
      );
      expect(empty.isValid, isFalse);
    });

    test('every preset is valid', () {
      for (final layout in [
        SeatLayout.busStandard49(),
        SeatLayout.busVipFront(),
        SeatLayout.airTwoClass(),
      ]) {
        expect(layout.isValid, isTrue);
        expect(layout.capacity, greaterThan(0));
      }
    });
  });
}
