/// How a printed ticket looks, as data.
///
/// **Why this exists.** Most seats in this market are still bought with cash,
/// across a counter, by somebody who will not install an app and may not own
/// a smartphone. That sale has to end with something in their hand, and that
/// something has to scan at the door exactly like a phone does. It can:
/// `LinkedSeat.payload` is the complete signed string and it is **static** —
/// the control at the door is one scan per seat, not freshness (ADR-0007,
/// ADR-0026). A printed QR is a first-class ticket, not a fallback.
///
/// **Why it is bounded, and not a design tool.** The vitrine settled this
/// argument once already: eight accents rather than a colour picker, four
/// generated motifs rather than photography. The reasons are stronger here,
/// because a ticket is read by a machine in a yard at half past five:
///
///   * a free colour picker guarantees somebody eventually prints a yellow
///     header that is invisible in direct sun, or a dark ground behind a QR
///     that a cheap scanner refuses;
///   * a free layout guarantees somebody eventually moves the QR under the
///     fold of a folded pass.
///
/// So an operator chooses from bounded things — a size, a hue, a motif, which
/// optional lines to print, a note of their own — and everything that makes
/// the ticket *work* is not theirs to move.
library;

/// The paper this is meant for.
enum TicketFormat {
  /// The default. A pass the size of an airline boarding card (DL, 210 × 99
  /// mm), laid out **three to an A4 sheet with cut marks**.
  ///
  /// This is the insight worth having about this market: an agency in
  /// Dolisie has an A4 inkjet and a ream of ordinary paper, not a thermal
  /// boarding-pass printer and rolls of card. Making the default "boarding
  /// pass" mean *special stock* would mean the default nobody can print.
  /// Three-up on A4 costs a pair of scissors and a third of a page.
  boardingPass,

  /// One ticket per A4 sheet, everything set larger.
  ///
  /// For an agency that would rather hand over a full page — it doubles as
  /// the customer's receipt — and for anybody whose printer eats narrow cuts.
  a4;

  String get labelKey => 'enum.TicketFormat.$name';

  /// CSS `@page size`, and the width the layout is composed at.
  ({String page, String width, String height}) get sheet => switch (this) {
    TicketFormat.boardingPass => (
      page: 'A4 portrait',
      width: '190mm',
      height: '88mm',
    ),
    TicketFormat.a4 => (page: 'A4 portrait', width: '190mm', height: '277mm'),
  };

  /// How many fit on one sheet.
  int get perSheet => switch (this) {
    TicketFormat.boardingPass => 3,
    TicketFormat.a4 => 1,
  };
}

/// An optional line. The required ones — route, time, seat, name, reference
/// and the QR — are not in this list, because they are not optional.
/// The list is short on purpose, and shorter than it will be. A printed
/// ticket can only offer what the link resolves, and `ticket_by_link()` today
/// returns the journey, the seats and the yard — not the amount paid and not
/// the stops along the road. Offering "print the price" as a switch that
/// silently prints nothing would be worse than not offering it, so the amount
/// and the vias arrive here when that function returns them, and not before.
enum TicketField {
  /// The yard, and the company's own directions to it.
  station,

  /// Arrival time. Honest but frequently wrong on a road with no timetable
  /// discipline, which is why an operator may decline to print it.
  arrival,

  /// "Be at the yard thirty minutes before" and the like.
  boardingNote;

  String get labelKey => 'enum.TicketField.$name';
}

/// One operator's printed ticket, as data.
final class TicketDesign {
  const TicketDesign({
    required this.format,
    this.accentHue = 'foret',
    this.motif = 'kuba',
    this.showLogo = true,
    this.fields = const {
      TicketField.station,
      TicketField.arrival,
      TicketField.boardingNote,
    },
    this.footerFr,
    this.footerEn,
    this.name,
  });

  final TicketFormat format;

  /// From the closed set on `operators.accent_hue`. Named, never a hex: the
  /// eight are contrast-checked against paper and against a screen in sun.
  final String accentHue;

  /// One of the four Kilo motifs, printed as a pale band behind the header.
  /// `flat` is a motif too — an operator who wants nothing gets nothing.
  final String motif;

  /// The operator's mark on the header. Off for one who has not uploaded a
  /// logo, and off for anybody who would rather spend the ink.
  final bool showLogo;

  final Set<TicketField> fields;

  /// The operator's own sentence at the foot — a phone number for the depot,
  /// a rule about luggage. 140 characters, in each language they sell in.
  final String? footerFr;
  final String? footerEn;

  /// What the operator called this design. Null on the starters until cloned.
  final String? name;

  static const footerMax = 140;

  bool shows(TicketField field) => fields.contains(field);

  TicketDesign copyWith({
    TicketFormat? format,
    String? accentHue,
    String? motif,
    bool? showLogo,
    Set<TicketField>? fields,
    String? footerFr,
    String? footerEn,
    String? name,
  }) => TicketDesign(
    format: format ?? this.format,
    accentHue: accentHue ?? this.accentHue,
    motif: motif ?? this.motif,
    showLogo: showLogo ?? this.showLogo,
    fields: fields ?? this.fields,
    footerFr: footerFr ?? this.footerFr,
    footerEn: footerEn ?? this.footerEn,
    name: name ?? this.name,
  );

  Map<String, Object?> toJson() => {
    'format': format.name,
    'accentHue': accentHue,
    'motif': motif,
    'showLogo': showLogo,
    'fields': [for (final f in fields) f.name],
    if (footerFr != null) 'footerFr': footerFr,
    if (footerEn != null) 'footerEn': footerEn,
    if (name != null) 'name': name,
  };

  /// Tolerant on the way in: a design saved by an older build, or by a build
  /// that knew a field this one does not, must still print a ticket. An
  /// unreadable design is a counter that cannot sell.
  factory TicketDesign.fromJson(Map<String, Object?> json) => TicketDesign(
    format: TicketFormat.values.firstWhere(
      (f) => f.name == json['format'],
      orElse: () => TicketFormat.boardingPass,
    ),
    accentHue: json['accentHue'] as String? ?? 'foret',
    motif: json['motif'] as String? ?? 'kuba',
    showLogo: json['showLogo'] as bool? ?? true,
    fields: {
      for (final name in (json['fields'] as List? ?? const []))
        ...TicketField.values.where((f) => f.name == name),
    },
    footerFr: json['footerFr'] as String?,
    footerEn: json['footerEn'] as String?,
    name: json['name'] as String?,
  );
}

/// The four an operator starts from.
///
/// **Starters, not themes.** Each is a complete, printable ticket that an
/// operator can use unchanged on their first day, and each makes a different
/// trade so the choice is about their counter rather than their taste:
/// how much ink, how much paper, how much the ticket has to explain.
///
/// An operator who never opens the builder prints [TicketStarters.classicPass]
/// in their own hue — which is the point of having defaults good enough to
/// skip (the vitrine's rule, applied here).
abstract final class TicketStarters {
  /// Three to a sheet, the woven band across the header, everything the
  /// traveller needs and nothing more. The default.
  static const classicPass = TicketDesign(
    format: TicketFormat.boardingPass,
    fields: {
      TicketField.station,
      TicketField.arrival,
      TicketField.boardingNote,
    },
  );

  /// The same size with the ink turned down: no motif, no logo, no arrival
  /// time. For an agency printing two hundred a day on a tired cartridge.
  static const economyPass = TicketDesign(
    format: TicketFormat.boardingPass,
    motif: 'flat',
    showLogo: false,
    fields: {TicketField.station},
  );

  /// A full page that doubles as the receipt: everything the link knows, and
  /// room at the foot for the company's own rules — luggage, the depot's
  /// telephone number, what happens to a missed coach.
  static const fullPageReceipt = TicketDesign(
    format: TicketFormat.a4,
    fields: {
      TicketField.station,
      TicketField.arrival,
      TicketField.boardingNote,
    },
  );

  /// A full page with the QR as large as the sheet allows and almost nothing
  /// else — for a yard where the light is bad and the scanner is old, and for
  /// a passenger who cannot read the small print.
  static const largePrintPage = TicketDesign(
    format: TicketFormat.a4,
    motif: 'flat',
    fields: {TicketField.station, TicketField.boardingNote},
  );

  static const all = [
    classicPass,
    economyPass,
    fullPageReceipt,
    largePrintPage,
  ];

  /// The key each is offered under in the console and named by in the
  /// catalog. Kept beside the constants so the two cannot drift.
  static const keys = {
    'classicPass': classicPass,
    'economyPass': economyPass,
    'fullPageReceipt': fullPageReceipt,
    'largePrintPage': largePrintPage,
  };

  static String keyOf(TicketDesign design) =>
      keys.entries.firstWhere((e) => identical(e.value, design)).key;
}
