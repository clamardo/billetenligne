import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// Putting one coach's passengers into another.
///
/// The rescue coach is the most common resolution to a breakdown here, and
/// the coach that turns up is rarely the coach that failed. Every claim below
/// is about what a passenger notices: where they are in the coach, and
/// whether they still have the window they chose.
void main() {
  SeatLayout twoByTwo(int rows) => SeatLayout(
    version: 1,
    mode: TransportMode.bus,
    sections: [
      CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: rows,
        abreast: '2+2',
      ),
    ],
  );

  SeatLayout twoByThree(int rows) => SeatLayout(
    version: 1,
    mode: TransportMode.bus,
    sections: [
      CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: rows,
        abreast: '2+3',
      ),
    ],
  );

  test('the same coach moves nobody', () {
    final remap = remapSeats(
      from: twoByTwo(12),
      to: twoByTwo(12),
      occupied: const ['1A', '6C', '12D'],
    );

    // A swap between two identical coaches — the most common one, because an
    // operator's spare is usually the same model — must not reissue forty-two
    // tickets for nothing.
    expect(remap.movedCount, 0);
    expect(remap.seatsEverybody, isTrue);
    expect(remap.destinationOf('6C'), '6C');
  });

  test('a window stays a window', () {
    // 1A is a window on a 2+2; on a 2+3 the letters mean different places,
    // and a remapper that just re-labels hands a window seat to somebody in
    // the middle of a three-across bench.
    final remap = remapSeats(
      from: twoByTwo(12),
      to: twoByThree(12),
      occupied: const ['1A', '1D'],
    );

    expect(remap.destinationOf('1A'), '1A');
    // The last seat of the last block — the other window.
    expect(remap.destinationOf('1D'), '1E');
  });

  test('a seat that does not exist lands at the same depth', () {
    // 12E is the back row of a 2+3 and there is no E on a 2+2, so this
    // passenger has to move. Relative position, not row number: a family that
    // booked the back row for the space does not want the front of a longer
    // coach.
    final remap = remapSeats(
      from: twoByThree(12),
      to: twoByTwo(15),
      occupied: const ['12E'],
    );

    expect(remap.destinationOf('12E'), startsWith('15'));
  });

  test('a seat that still exists is simply kept', () {
    // The rule stated to a passenger in one sentence: you keep your seat if
    // it exists on the new coach. Moving somebody who did not have to move
    // means a reissued ticket and a message, both for nothing.
    final remap = remapSeats(
      from: twoByTwo(12),
      to: twoByTwo(15),
      occupied: const ['12A'],
    );

    expect(remap.destinationOf('12A'), '12A');
    expect(remap.movedCount, 0);
  });

  test('a smaller coach names who it cannot seat', () {
    final remap = remapSeats(
      from: twoByTwo(3),
      to: twoByTwo(2),
      occupied: const ['1A', '1B', '1C', '1D', '2A', '2B', '2C', '2D', '3A'],
    );

    // Eight seats for nine passengers. The ninth is named, because a remap
    // that silently loses somebody is a passenger who finds out at the door.
    expect(remap.unplaceable, isNotEmpty);
    expect(remap.seatsEverybody, isFalse);
    expect(remap.moves.length + remap.unplaceable.length, 9);
  });

  test('the one it cannot seat is the one furthest back', () {
    final remap = remapSeats(
      from: twoByTwo(3),
      to: twoByTwo(2),
      occupied: const ['1A', '1B', '1C', '1D', '2A', '2B', '2C', '2D', '3A'],
    );

    // Front to back, so the passengers who keep their place are the ones
    // whose place still exists. Which passenger is displaced is arbitrary in
    // fairness terms and is not arbitrary in *predictability* terms — a
    // dispatcher asked "why her?" can answer.
    expect(remap.unplaceable, ['3A']);
  });

  test('a seat the old layout never had is surfaced, not swallowed', () {
    // The departure and its layout have already disagreed. That is a bug, and
    // the honest place for it to appear is beside the passenger it affects.
    final remap = remapSeats(
      from: twoByTwo(2),
      to: twoByTwo(2),
      occupied: const ['1A', '9Z'],
    );

    expect(remap.unplaceable, ['9Z']);
    expect(remap.destinationOf('1A'), '1A');
  });

  test('nobody is seated twice', () {
    final layout = SeatLayout.busStandard49();
    final occupied = layout.allSeatLabels().take(30).toList();

    final remap = remapSeats(
      from: layout,
      to: SeatLayout.busVipFront(),
      occupied: occupied,
    );

    final destinations = remap.moves.map((m) => m.to).toList();
    // The property that a rewrite of this function must not lose: two
    // passengers in one seat is an argument at the door of a coach that has
    // already broken down once today.
    expect(destinations.toSet().length, destinations.length);
    expect(remap.moves.length + remap.unplaceable.length, 30);
  });

  test('a blocked seat in the rescue coach is not offered', () {
    final rescue = SeatLayout(
      version: 1,
      mode: TransportMode.bus,
      sections: twoByTwo(2).sections,
      blocked: const {'1A'},
    );

    final remap = remapSeats(
      from: twoByTwo(2),
      to: rescue,
      occupied: const ['1A'],
    );

    // Blocked is blocked whatever the reason — a broken seat, a wheel arch —
    // and seating somebody in one is how a conductor discovers it.
    expect(remap.destinationOf('1A'), isNot('1A'));
    expect(remap.seatsEverybody, isTrue);
  });
}
