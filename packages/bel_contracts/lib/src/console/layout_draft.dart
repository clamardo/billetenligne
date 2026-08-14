import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// A layout being drawn in the console, on its way to `POST /fleet/layouts`.
///
/// The wire shape lives here rather than in the screen because three places
/// have to agree on it: the console that sends it, the route that parses it,
/// and the test that proves a section survives the round trip. A screen that
/// built its own map would agree with the route only until somebody renamed a
/// field, and the failure would be a 400 an operator sees rather than a
/// compile error a developer sees (ADR-0004).
///
/// It carries [CabinSection] from the domain rather than a parallel set of
/// fields, so the capacity the operator watches while they draw is computed by
/// the same code that will sell the seats.
final class LayoutDraft {
  const LayoutDraft({
    required this.name,
    this.mode = TransportMode.bus,
    this.sections = const [],
    this.blocked = const {},
    this.features = const [],
  });

  final String name;
  final TransportMode mode;
  final List<CabinSection> sections;

  /// Seats that exist and are not for sale — a wheel arch under 7C, a seat
  /// with no window an operator refuses to sell as one.
  ///
  /// **Not a shorter section.** The seat keeps its label, so the manifest, the
  /// ticket and the conductor's count all still agree with the physical coach;
  /// what changes is only whether it can be bought.
  final Set<String> blocked;

  /// Doors, stairs, the lavatory. Drawn on the seat map so a traveller
  /// choosing 12A knows it is beside the WC before they pay rather than after.
  final List<LayoutFeature> features;

  /// Whether the server would accept it. Asked *before* the request, so the
  /// save button is disabled with a reason rather than enabled into a 400.
  bool get isValid =>
      name.trim().isNotEmpty && layout.isValid && layout.capacity > 0;

  SeatLayout get layout => SeatLayout(
    version: 1,
    mode: mode,
    sections: sections,
    features: features,
    blocked: blocked,
  );

  /// What the operator is watching while they draw. Every keystroke changes
  /// it, which is the whole point of a builder over a form.
  int get capacity => layout.capacity;

  /// The row a new section should start at, so sections stay contiguous
  /// without the operator counting. Wrong only when they meant to overlap,
  /// which they can still say by editing the field.
  int get nextStartRow => sections.isEmpty
      ? 1
      : sections
            .map((s) => s.startRow + s.rows)
            .reduce((a, b) => a > b ? a : b);

  LayoutDraft copyWith({
    String? name,
    TransportMode? mode,
    List<CabinSection>? sections,
    Set<String>? blocked,
    List<LayoutFeature>? features,
  }) => LayoutDraft(
    name: name ?? this.name,
    mode: mode ?? this.mode,
    sections: sections ?? this.sections,
    blocked: blocked ?? this.blocked,
    features: features ?? this.features,
  );

  Map<String, Object?> toJson() => {
    'name': name.trim(),
    'mode': mode.name,
    'sections': [for (final s in sections) encodeSection(s)],
    // Sorted, so two drafts describing the same coach produce the same bytes.
    // A `Set` has no order, and an unordered list on the wire is a diff that
    // reports a change nobody made.
    'blocked': blocked.toList()..sort(),
    'features': [
      for (final f in features)
        {'type': f.type.name, 'row': f.row, 'col': f.col},
    ],
  };

  /// One section, in the shape the route reads.
  ///
  /// The modifier is flattened to whichever of the two fields applies, and
  /// never both: the server refuses a section that names a multiplier and a
  /// supplement at once, because that is not a tie to break — it is a request
  /// nobody meant to send.
  static Map<String, Object?> encodeSection(CabinSection s) => Wire.compact({
    'code': s.code,
    'labelKey': s.labelKey,
    'rows': s.rows,
    'abreast': s.abreast,
    'startRow': s.startRow,
    'numbering': s.numbering.name,
    'pitchCm': s.pitchCm,
    'fareMultiplier': switch (s.modifier) {
      MultiplierModifier(:final value) => value,
      _ => null,
    },
    'fareSupplement': switch (s.modifier) {
      SupplementModifier(:final minor) => minor,
      _ => null,
    },
  });

  static CabinSection decodeSection(Map<String, Object?> json) {
    final multiplier = json['fareMultiplier'];
    final supplement = json['fareSupplement'];
    return CabinSection(
      code: Wire.requireString(json['code'], 'code'),
      labelKey: Wire.requireString(json['labelKey'], 'labelKey'),
      rows: Wire.requireInt(json['rows'], 'rows'),
      abreast: Wire.requireString(json['abreast'], 'abreast'),
      startRow: json['startRow'] as int? ?? 1,
      numbering: json['numbering'] == 'sequential'
          ? SeatNumbering.sequential
          : SeatNumbering.rowLetter,
      pitchCm: json['pitchCm'] as int?,
      modifier: switch ((multiplier, supplement)) {
        (final num m, _) => PriceModifier.multiplier(m.toDouble()),
        (_, final int s) => PriceModifier.supplementMinor(s),
        _ => null,
      },
    );
  }
}
