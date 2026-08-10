import '../money/money.dart';
import 'transport_mode.dart';

/// How seats in a section are labelled.
enum SeatNumbering { rowLetter, sequential }

/// A price modifier attached to a cabin section.
sealed class PriceModifier {
  const PriceModifier();
  const factory PriceModifier.multiplier(double value) = MultiplierModifier;
  const factory PriceModifier.supplementMinor(int value) = SupplementModifier;

  /// The fare for a seat in this section, given the departure's base fare.
  ///
  /// Rounded to the nearest minor unit, once, here. Doing it at each call site
  /// is how the seat map quotes 13 500 and the booking charges 13 499 — and a
  /// traveller who spots a one-franc difference stops trusting every other
  /// number on the screen.
  Money applyTo(Money base) => switch (this) {
    MultiplierModifier(:final value) => Money(
      (base.minor * value).round(),
      base.currency,
    ),
    SupplementModifier(:final minor) => Money(
      base.minor + minor,
      base.currency,
    ),
  };
}

final class MultiplierModifier extends PriceModifier {
  const MultiplierModifier(this.value);
  final double value;
}

final class SupplementModifier extends PriceModifier {
  const SupplementModifier(this.minor);
  final int minor;
}

/// Non-seat elements placed on the layout grid.
enum LayoutFeatureType {
  door,
  wc,
  galley,
  exit,
  luggage,
  driver,
  cockpit,
  stairs,
}

final class LayoutFeature {
  const LayoutFeature(this.type, {required this.row, required this.col});
  final LayoutFeatureType type;
  final int row;
  final int col;
}

/// The `2+3` notation, and what it is allowed to say.
///
/// A validated parser rather than `int.parse` at the point of use, because
/// this string arrives from an operator's console over HTTP. Three things it
/// used to let through, every one of them reachable by an authenticated
/// vendor:
///
///   * `abc` threw a `FormatException` out of a capacity getter — a 500 on a
///     request whose only problem was a typo;
///   * `-4+2` gave a section a **negative** seat count, which then made a
///     layout's capacity smaller than the seats it actually contained;
///   * `9+9` asked for eighteen seats across and walked off the end of the
///     letter table with a `RangeError`.
///
/// The cap is ten, which is the width of the letter table and also wider than
/// anything that carries passengers — a 3+4+3 widebody is exactly ten.
abstract final class Abreast {
  /// A..K with I skipped, because a capital I reads as a 1 on a seat sticker.
  static const letters = 'ABCDEFGHJK';

  static const maxSeatsPerRow = letters.length;

  /// Four blocks would be three aisles. Nothing that carries passengers has
  /// more, and a section that claims to is a section drawn by accident.
  static const maxBlocks = 4;

  /// The seats in each block, or null when the notation is not one we accept.
  static List<int>? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final groups = trimmed.split('+');
    if (groups.isEmpty || groups.length > maxBlocks) return null;

    final blocks = <int>[];
    var total = 0;
    for (final group in groups) {
      final size = int.tryParse(group.trim());
      // Zero is refused as well as negative: an empty block is an aisle
      // written twice, and `2++2` should be a refusal rather than a shrug.
      if (size == null || size < 1) return null;
      total += size;
      if (total > maxSeatsPerRow) return null;
      blocks.add(size);
    }
    return blocks;
  }

  static bool isValid(String raw) => parse(raw) != null;
}

/// One cabin section: "3 rows of 2+3 in first class".
///
/// This is the abstraction that lets a single designer serve a 2+2 coach, a
/// VIP-front coach and a two-class aircraft with no special cases
/// (ADR-0017 §3). The 5-across rear bench every generic tool forgets is
/// simply a one-row section.
final class CabinSection {
  const CabinSection({
    required this.code,
    required this.labelKey,
    required this.rows,
    required this.abreast,
    this.numbering = SeatNumbering.rowLetter,
    this.startRow = 1,
    this.modifier,
    this.pitchCm,
  });

  final String code;
  final String labelKey;
  final int rows;

  /// e.g. `2+2`, `2+3`, `3+3`, `1+1`. Each group is one block of seats and
  /// the `+` marks an aisle.
  final String abreast;

  final SeatNumbering numbering;
  final int startRow;
  final PriceModifier? modifier;
  final int? pitchCm;

  /// Empty when [abreast] is not notation we accept, so nothing downstream
  /// throws. A section that cannot be read has no seats, and the edge that
  /// accepted it is what should have said so — see [isValid].
  List<int> get blocks => Abreast.parse(abreast) ?? const [];

  /// Whether this section is one we can actually draw. Checked at the edge
  /// that accepts it, so a typo is a 400 naming the field rather than a 500.
  bool get isValid => rows > 0 && Abreast.isValid(abreast);

  int get seatsPerRow => blocks.fold(0, (a, b) => a + b);
  int get capacity => rows * seatsPerRow;

  /// Seat labels in physical order, front to back, left to right.
  ///
  /// Labels follow the sticker on the seat, not our database — the conductor
  /// reads the vehicle, not the schema.
  List<String> seatLabels({int sequentialOffset = 0}) {
    const letters = Abreast.letters; // I is skipped — reads as 1
    final out = <String>[];
    var seq = sequentialOffset;
    for (var r = 0; r < rows; r++) {
      var indexInRow = 0;
      for (final block in blocks) {
        for (var s = 0; s < block; s++) {
          out.add(switch (numbering) {
            SeatNumbering.rowLetter => '${startRow + r}${letters[indexInRow]}',
            SeatNumbering.sequential => '${++seq}',
          });
          indexInRow++;
        }
      }
    }
    return out;
  }
}

/// A complete, versioned seat layout. Immutable once a departure references
/// it — editing a template creates a new version, and sold departures keep
/// the layout they were sold with (ADR-0015's versioning principle applied
/// to inventory).
final class SeatLayout {
  const SeatLayout({
    required this.version,
    required this.mode,
    required this.sections,
    this.features = const [],
    this.blocked = const {},
  });

  final int version;
  final TransportMode mode;
  final List<CabinSection> sections;
  final List<LayoutFeature> features;
  final Set<String> blocked;

  /// Total sellable seats: every seat in every section, minus blocked ones.
  int get capacity => allSeatLabels().where((s) => !blocked.contains(s)).length;

  int get grossCapacity => sections.fold(0, (sum, s) => sum + s.capacity);

  /// Whether every section can be drawn, and there is at least one.
  ///
  /// A layout with no sections has no seats, which makes a departure that
  /// nobody can book — and a vehicle assigned one would fail at the moment a
  /// dispatcher published a timetable rather than at the moment somebody
  /// saved it.
  bool get isValid => sections.isNotEmpty && sections.every((s) => s.isValid);

  List<String> allSeatLabels() {
    final out = <String>[];
    var offset = 0;
    for (final section in sections) {
      final labels = section.seatLabels(sequentialOffset: offset);
      out.addAll(labels);
      offset += section.capacity;
    }
    return out;
  }

  /// What one seat costs on a departure whose base fare is [base].
  ///
  /// The section owns the modifier, so a VIP row is priced by the layout
  /// rather than by a special case in the sales path — which is what lets the
  /// same code sell a 2+2 coach and a two-class cabin (ADR-0017).
  Money fareFor(String label, Money base) =>
      sectionForSeat(label)?.modifier?.applyTo(base) ?? base;

  CabinSection? sectionForSeat(String label) {
    var offset = 0;
    for (final section in sections) {
      final labels = section.seatLabels(sequentialOffset: offset);
      if (labels.contains(label)) return section;
      offset += section.capacity;
    }
    return null;
  }

  /// Common presets, so most operators never open the editor
  /// (`06-fleet-and-routes.md` §3.2).
  static SeatLayout busStandard49() => const SeatLayout(
    version: 1,
    mode: TransportMode.bus,
    sections: [
      CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: 11,
        abreast: '2+2',
      ),
      CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: 1,
        abreast: '5',
        startRow: 12,
      ),
    ],
    features: [
      LayoutFeature(LayoutFeatureType.driver, row: 0, col: 0),
      LayoutFeature(LayoutFeatureType.door, row: 0, col: 4),
    ],
  );

  static SeatLayout busVipFront() => const SeatLayout(
    version: 1,
    mode: TransportMode.bus,
    sections: [
      CabinSection(
        code: 'VIP',
        labelKey: 'seat.class.vip',
        rows: 3,
        abreast: '1+2',
        modifier: PriceModifier.multiplier(1.5),
        pitchCm: 90,
      ),
      CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: 10,
        abreast: '2+2',
        startRow: 4,
      ),
    ],
  );

  /// The layout the brief described out loud: "two first class 3 rows of 5
  /// and second class 10 rows of 5".
  static SeatLayout airTwoClass() => const SeatLayout(
    version: 1,
    mode: TransportMode.air,
    sections: [
      CabinSection(
        code: 'F',
        labelKey: 'seat.class.first',
        rows: 3,
        abreast: '2+3',
        modifier: PriceModifier.multiplier(2.5),
        pitchCm: 100,
      ),
      CabinSection(
        code: 'Y',
        labelKey: 'seat.class.economy',
        rows: 10,
        abreast: '2+3',
        startRow: 4,
        pitchCm: 76,
      ),
    ],
    features: [
      LayoutFeature(LayoutFeatureType.cockpit, row: 0, col: 0),
      LayoutFeature(LayoutFeatureType.exit, row: 7, col: 0),
      LayoutFeature(LayoutFeatureType.wc, row: 13, col: 2),
    ],
  );
}
