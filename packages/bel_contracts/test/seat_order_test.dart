import 'package:bel_contracts/bel_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('seat labels are ordered as a coach is read', () {
    // A text sort puts 10A before 1A. The client trusts the order it is
    // given — `KSeatMap` chunks the list into rows of `seatsPerRow` — so a
    // coach with more than nine rows was drawn with row 10 at the front and
    // one row reading `12E 1A 1B 1C`.
    test('the tenth row follows the ninth, not the first', () {
      final labels = ['10A', '1A', '2A', '9A', '12E', '12A']
        ..sort(SeatDto.compareLabels);

      expect(labels, ['1A', '2A', '9A', '10A', '12A', '12E']);
    });

    test('within a row, seats keep their letters in order', () {
      final labels = ['12E', '12A', '12D', '12B']..sort(SeatDto.compareLabels);

      expect(labels, ['12A', '12B', '12D', '12E']);
    });

    // Operators name their own seats and not all of them count from one.
    // Whatever they choose, two coaches must not draw differently for the
    // same input, so the rule is a total order rather than one with holes.
    test('a label that starts with no digit still has a place', () {
      final labels = ['2A', 'CREW', '1A']..sort(SeatDto.compareLabels);

      expect(labels, ['1A', '2A', 'CREW']);
    });

    test('ordering the same list twice gives the same answer', () {
      final once = ['3B', 'W1', '3A', '11C']..sort(SeatDto.compareLabels);
      final twice = ['11C', '3A', 'W1', '3B']..sort(SeatDto.compareLabels);

      expect(once, twice);
    });
  });
}
