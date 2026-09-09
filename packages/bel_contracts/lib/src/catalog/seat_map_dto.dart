import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// One seat's live state on one departure.
enum SeatStatusDto { available, held, sold, blocked }

final class SeatDto {
  const SeatDto({
    required this.label,
    required this.status,
    required this.sectionCode,
    this.fare,
  });

  final String label;
  final SeatStatusDto status;

  /// Which cabin section it belongs to, so the client can price and label it
  /// without re-deriving the layout (ADR-0017).
  final String sectionCode;

  /// Section pricing already applied. Sent per seat so a VIP row never
  /// surprises anyone at checkout.
  final Money? fare;

  Map<String, Object?> toJson() => Wire.compact({
    'label': label,
    'status': status.name,
    'sectionCode': sectionCode,
    'fare': fare == null ? null : Wire.money(fare!),
  });

  factory SeatDto.fromJson(Map<String, Object?> json) => SeatDto(
    label: Wire.requireString(json['label'], 'label'),
    status: Wire.readEnum(
      json['status'],
      SeatStatusDto.values,
      field: 'status',
    ),
    sectionCode: Wire.requireString(json['sectionCode'], 'sectionCode'),
    fare: json['fare'] == null
        ? null
        : Wire.readMoney(json['fare'], field: 'fare'),
  );

  bool get isSelectable => status == SeatStatusDto.available;

  /// Two seat labels in the order a coach is actually read.
  ///
  /// A seat label is text, and a text sort puts `10A` before `1A`. The seat
  /// map draws whatever order it is handed — `KSeatMap` chunks the list into
  /// rows of `seatsPerRow` rather than re-deriving the deck from the labels —
  /// so any coach with more than nine rows came out with row 10 at the front
  /// and one row reading `12E 1A 1B 1C`.
  ///
  /// Postgres orders by this same rule in `postgres_departure_catalogue`,
  /// where it is the database's job. This is the version every other adapter
  /// uses, so the two cannot quietly disagree about what a coach looks like.
  ///
  /// The leading number first, then the label itself: `12E` follows `12A`,
  /// and a label with no leading digit at all — an operator who names a jump
  /// seat `CREW` — still lands in one fixed place rather than an arbitrary
  /// one. A total order, because two coaches with the same seats must never
  /// draw differently.
  static int compareLabels(String a, String b) {
    final rowA = _leadingNumber(a);
    final rowB = _leadingNumber(b);
    if (rowA != rowB) {
      // Numbered rows first, in numeric order; anything unnumbered after
      // them. This is `NULLS LAST` on the SQL side.
      if (rowA == null) return 1;
      if (rowB == null) return -1;
      return rowA.compareTo(rowB);
    }
    return a.compareTo(b);
  }

  static int? _leadingNumber(String label) {
    var end = 0;
    while (end < label.length && _isDigit(label.codeUnitAt(end))) {
      end++;
    }
    // `tryParse` rather than `parse`: a label of forty digits is somebody
    // else's bug, and a comparator is not the place to throw over it.
    return end == 0 ? null : int.tryParse(label.substring(0, end));
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
}

final class CabinSectionDto {
  const CabinSectionDto({
    required this.code,
    required this.labelKey,
    required this.rows,
    required this.abreast,
    this.pitchCm,
  });

  final String code;
  final String labelKey;
  final int rows;
  final String abreast;
  final int? pitchCm;

  Map<String, Object?> toJson() => Wire.compact({
    'code': code,
    'labelKey': labelKey,
    'rows': rows,
    'abreast': abreast,
    'pitchCm': pitchCm,
  });

  factory CabinSectionDto.fromJson(Map<String, Object?> json) =>
      CabinSectionDto(
        code: Wire.requireString(json['code'], 'code'),
        labelKey: Wire.requireString(json['labelKey'], 'labelKey'),
        rows: Wire.requireInt(json['rows'], 'rows'),
        abreast: Wire.requireString(json['abreast'], 'abreast'),
        pitchCm: json['pitchCm'] as int?,
      );

  factory CabinSectionDto.fromDomain(CabinSection s) => CabinSectionDto(
    code: s.code,
    labelKey: s.labelKey,
    rows: s.rows,
    abreast: s.abreast,
    pitchCm: s.pitchCm,
  );
}

final class LayoutFeatureDto {
  const LayoutFeatureDto({
    required this.type,
    required this.row,
    required this.col,
  });

  final String type;
  final int row;
  final int col;

  Map<String, Object?> toJson() => {'type': type, 'row': row, 'col': col};

  factory LayoutFeatureDto.fromJson(Map<String, Object?> json) =>
      LayoutFeatureDto(
        type: Wire.requireString(json['type'], 'type'),
        row: Wire.requireInt(json['row'], 'row'),
        col: Wire.requireInt(json['col'], 'col'),
      );
}

/// The seat map for one departure: the layout plus live availability.
///
/// Sent as one response because the client needs both to draw anything, and
/// two round trips on 2G is a visibly slower screen.
final class SeatMapDto {
  const SeatMapDto({
    required this.departureId,
    required this.mode,
    required this.layoutVersion,
    required this.sections,
    required this.seats,
    this.features = const [],
  });

  final String departureId;
  final String mode;

  /// Which layout version this departure was sold under. Editing a template
  /// creates a new version; sold departures keep theirs (ADR-0015's
  /// versioning principle applied to inventory).
  final int layoutVersion;

  final List<CabinSectionDto> sections;
  final List<SeatDto> seats;
  final List<LayoutFeatureDto> features;

  int get availableCount =>
      seats.where((s) => s.status == SeatStatusDto.available).length;

  Map<String, Object?> toJson() => {
    'departureId': departureId,
    'mode': mode,
    'layoutVersion': layoutVersion,
    'sections': [for (final s in sections) s.toJson()],
    'seats': [for (final s in seats) s.toJson()],
    'features': [for (final f in features) f.toJson()],
  };

  factory SeatMapDto.fromJson(Map<String, Object?> json) => SeatMapDto(
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    mode: Wire.requireString(json['mode'], 'mode'),
    layoutVersion: Wire.requireInt(json['layoutVersion'], 'layoutVersion'),
    sections: Wire.readList(
      json['sections'],
      CabinSectionDto.fromJson,
      field: 'sections',
    ),
    seats: Wire.readList(json['seats'], SeatDto.fromJson, field: 'seats'),
    features: Wire.readList(
      json['features'],
      LayoutFeatureDto.fromJson,
      field: 'features',
    ),
  );
}
