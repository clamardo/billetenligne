import 'transport_mode.dart';

/// How seats in a section are labelled.
enum SeatNumbering { rowLetter, sequential }

/// A price modifier attached to a cabin section.
sealed class PriceModifier {
  const PriceModifier();
  const factory PriceModifier.multiplier(double value) = MultiplierModifier;
  const factory PriceModifier.supplementMinor(int value) = SupplementModifier;
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

  List<int> get blocks => abreast
      .split('+')
      .map((p) => int.parse(p.trim()))
      .toList(growable: false);

  int get seatsPerRow => blocks.fold(0, (a, b) => a + b);
  int get capacity => rows * seatsPerRow;

  /// Seat labels in physical order, front to back, left to right.
  ///
  /// Labels follow the sticker on the seat, not our database — the conductor
  /// reads the vehicle, not the schema.
  List<String> seatLabels({int sequentialOffset = 0}) {
    const letters = 'ABCDEFGHJK'; // I is skipped — reads as 1
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
