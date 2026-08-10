import '../catalog/seat_layout.dart';

/// Where somebody sat, and where they will sit.
final class SeatMove {
  const SeatMove({required this.from, required this.to});

  final String from;
  final String to;

  bool get isUnchanged => from == to;
}

/// The result of putting one coach's passengers into another coach.
final class SeatRemap {
  const SeatRemap({required this.moves, required this.unplaceable});

  /// Every occupied seat, including the ones that keep their label. A
  /// dispatcher reading "3 passengers moved" needs the other thirty-nine to
  /// be accounted for rather than absent.
  final List<SeatMove> moves;

  /// Seats with nowhere to go, because the new coach is smaller.
  ///
  /// Named rather than dropped. A remap that quietly seats forty-two people
  /// in a forty-five-seat coach and loses three of them is the worst
  /// available outcome — the three find out at the door.
  final List<String> unplaceable;

  bool get seatsEverybody => unplaceable.isEmpty;

  int get movedCount => moves.where((m) => !m.isUnchanged).length;

  String? destinationOf(String label) {
    for (final move in moves) {
      if (move.from == label) return move.to;
    }
    return null;
  }
}

/// Where a seat is in its row. The three kinds a passenger actually notices.
enum SeatKind { window, aisle, middle }

/// One seat's place in a coach, as a fraction of the way back and a kind.
final class _Place {
  const _Place(this.label, this.depth, this.kind);

  final String label;

  /// 0.0 at the very front, 1.0 at the very back. A **fraction**, not a row
  /// number, because the whole point is to compare a 49-seat coach with a
  /// 45-seat one — row 12 of 12 and row 12 of 15 are not the same place.
  final double depth;

  final SeatKind kind;
}

/// Puts the passengers of one coach into another.
///
/// The rule is the one `08-disruption.md` §2.3 states: **preserve relative
/// position and window/aisle preference where possible.** Seat 14A on a 2+2
/// coach does not exist on a 2+3 layout, and a remapper that just re-labels
/// front-to-back moves the family at the back of the coach to the front and
/// puts somebody who paid for a window in the middle of a bench.
///
/// Explainable on purpose, like the ranking function in §2.2: a dispatcher
/// asked "why is she in 12C?" must be able to answer. Each passenger takes
/// the free seat that is closest to where they were, measured as a fraction
/// of the way down the coach, with a penalty for changing kind — so a window
/// seat two rows away beats a middle seat in the same row.
///
/// [occupied] is taken in the order the caller has them; the result is
/// deterministic regardless, because assignment is by depth.
SeatRemap remapSeats({
  required SeatLayout from,
  required SeatLayout to,
  required List<String> occupied,
}) {
  final source = {for (final p in _places(from)) p.label: p};
  final free = _places(to).where((p) => !to.blocked.contains(p.label)).toList();

  // Front to back. Assigning in physical order is what keeps a group that was
  // sitting together from being scattered by the order rows arrived in.
  final passengers =
      occupied.where(source.containsKey).map((l) => source[l]!).toList()
        ..sort((a, b) => a.depth.compareTo(b.depth));

  // A seat we cannot even find in the old layout is not a seat we can move.
  // It means the departure and its layout have already disagreed, which is a
  // bug worth surfacing as an unplaceable passenger rather than swallowing.
  final unknown = occupied.where((l) => !source.containsKey(l)).toList();

  final moves = <SeatMove>[];
  final unplaceable = <String>[...unknown];

  // Pass one: **you keep your seat if it still exists.** Same label, same
  // kind, not blocked. A swap between two identical coaches — an operator's
  // spare is usually the same model — must move nobody and reissue nothing,
  // and this is the rule that says so in one sentence to a passenger who
  // asks.
  //
  // The kind has to match too: 1D is a window on a 2+2 and a middle seat on a
  // 2+3, and keeping the label there would quietly demote somebody who chose
  // a window.
  final remaining = <_Place>[];
  for (final passenger in passengers) {
    final index = free.indexWhere(
      (p) => p.label == passenger.label && p.kind == passenger.kind,
    );
    if (index < 0) {
      remaining.add(passenger);
      continue;
    }
    free.removeAt(index);
    moves.add(SeatMove(from: passenger.label, to: passenger.label));
  }

  for (final passenger in remaining) {
    if (free.isEmpty) {
      unplaceable.add(passenger.label);
      continue;
    }

    var bestIndex = 0;
    var bestCost = double.infinity;
    for (var i = 0; i < free.length; i++) {
      final candidate = free[i];
      final cost =
          (candidate.depth - passenger.depth).abs() +
          (candidate.kind == passenger.kind ? 0 : _kindPenalty);
      if (cost < bestCost) {
        bestCost = cost;
        bestIndex = i;
      }
    }

    final chosen = free.removeAt(bestIndex);
    moves.add(SeatMove(from: passenger.label, to: chosen.label));
  }

  return SeatRemap(moves: moves, unplaceable: unplaceable);
}

/// How much a lost window is worth, in units of "fraction of the coach".
///
/// 0.15 — about a fifth of the coach. Larger than a couple of rows and
/// smaller than half the cabin: somebody who booked a window will accept
/// moving a few rows to keep it, and will not accept being sent from the
/// front to the back for it.
const _kindPenalty = 0.15;

List<_Place> _places(SeatLayout layout) {
  final out = <_Place>[];
  final rows = <List<(String, SeatKind)>>[];

  var offset = 0;
  for (final section in layout.sections) {
    final labels = section.seatLabels(sequentialOffset: offset);
    final blocks = section.blocks;
    final perRow = section.seatsPerRow;
    offset += section.capacity;
    if (perRow == 0) continue;

    for (var r = 0; r < section.rows; r++) {
      final row = <(String, SeatKind)>[];
      var index = 0;
      for (var b = 0; b < blocks.length; b++) {
        for (var s = 0; s < blocks[b]; s++) {
          final label = labels[r * perRow + index];
          row.add((label, _kindAt(b, s, blocks)));
          index++;
        }
      }
      rows.add(row);
    }
  }

  for (var r = 0; r < rows.length; r++) {
    // Midpoint of the row, so a single-row coach is 0.5 rather than 0 — and
    // so front and back are symmetric.
    final depth = rows.length == 1 ? 0.5 : r / (rows.length - 1);
    for (final (label, kind) in rows[r]) {
      out.add(_Place(label, depth, kind));
    }
  }

  return out;
}

/// Window at the outer edge of the outer blocks, aisle beside a gap, middle
/// otherwise. On a 2+3 the middle of the rear block is a middle seat, which
/// is exactly the seat nobody wants and the one this function exists to
/// avoid handing to somebody who had a window.
SeatKind _kindAt(int block, int seat, List<int> blocks) {
  final isFirstBlock = block == 0;
  final isLastBlock = block == blocks.length - 1;
  final isFirstSeat = seat == 0;
  final isLastSeat = seat == blocks[block] - 1;

  if ((isFirstBlock && isFirstSeat) || (isLastBlock && isLastSeat)) {
    return SeatKind.window;
  }
  if ((isLastSeat && !isLastBlock) || (isFirstSeat && !isFirstBlock)) {
    return SeatKind.aisle;
  }
  return SeatKind.middle;
}
