import 'package:flutter/widgets.dart';

/// Two faces, both bundled and subset, neither ever fetched.
///
/// **Inter carries the interface.** Drawn for screens, unambiguous at 12 px on
/// a scratched panel, and it has the tabular figure set this product is built
/// on. **Fraunces carries the headlines** — a warm editorial serif with a
/// `SOFT` axis and a `WONK` axis, which is what gives a page a voice instead
/// of a wireframe's silence.
///
/// Both are variable fonts subset to Latin, French diacritics and the
/// punctuation this product actually prints: 1.2 MB of source became 344 KB,
/// and one file per family covers every weight from 100 to 900 rather than
/// four static instances that cannot interpolate between them.
///
/// **Tabular figures are mandatory** on every price, time, seat number,
/// countdown and reference code. Amounts that shift width as digits change
/// look untrustworthy, and this app is made entirely of numbers people care
/// about. `tnum` survives the subset on purpose — `pyftsubset` drops it by
/// default, which would have quietly undone the most important typographic
/// decision here.
///
/// **Fraunces has no arrow and no narrow no-break space.** Not a subsetting
/// loss — the source face never had them. So a display style must never carry
/// a formatted amount (`Money.format` writes U+202F) or a `→` between two
/// cities: those go in Inter, or the arrow becomes a painted glyph, which is
/// better typography anyway. Anything else falls back mid-word to whatever the
/// platform has, and that is visible.
@immutable
final class KiloTypography {
  const KiloTypography(this._color);
  final Color _color;

  /// Both live in `bel_design`, so consumers name them through the package.
  static const family = 'packages/bel_design/Inter';
  static const displayFamily = 'packages/bel_design/Fraunces';

  /// Tabular figures. The single most important typographic decision here.
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  // ── Display: Fraunces ──────────────────────────────────────────────────
  //
  // `opsz` is a real optical size axis, so it is set to the point size rather
  // than left at the default — a display face at 40 px wants different
  // proportions from the same face at 20 px, and that is the whole argument
  // for a variable font over four static weights.

  /// The one line at the top of a hero. Used once per screen or not at all.
  TextStyle get displayXl => _serif(40, 44, FontWeight.w600, opsz: 40);

  TextStyle get display => _serif(32, 38, FontWeight.w600, opsz: 32);

  /// A screen's title.
  TextStyle get h1 => _serif(26, 32, FontWeight.w600, opsz: 26);

  // ── Interface: Inter ───────────────────────────────────────────────────
  //
  // From h2 down it is Inter: these sit next to data, in tables and rows,
  // where a serif starts competing with the numbers instead of introducing
  // them.

  TextStyle get h2 => _base(21, 28, FontWeight.w600);
  TextStyle get h3 => _base(17, 24, FontWeight.w600);
  TextStyle get bodyLg => _base(17, 26, FontWeight.w400);
  TextStyle get body => _base(15, 22, FontWeight.w400);
  TextStyle get bodySm => _base(13, 18, FontWeight.w400);
  TextStyle get caption => _base(12, 16, FontWeight.w400);

  /// Small, wide and uppercase-ish: the label above a section, not a heading.
  TextStyle get label =>
      _base(12, 16, FontWeight.w600).copyWith(letterSpacing: 0.8);

  /// Departure time on a search result — the largest thing on the card,
  /// because people choose a coach by when it goes.
  TextStyle get timeHero => _base(28, 32, FontWeight.w600, tabular: true);
  TextStyle get time => _base(20, 24, FontWeight.w600, tabular: true);

  TextStyle get amountHero => _base(30, 34, FontWeight.w700, tabular: true);
  TextStyle get amount => _base(17, 22, FontWeight.w600, tabular: true);
  TextStyle get amountSm => _base(14, 18, FontWeight.w500, tabular: true);

  /// Booking references, OTP, the rotating ticket code.
  TextStyle get code =>
      _base(16, 20, FontWeight.w600, tabular: true).copyWith(letterSpacing: 2);

  /// The reference on the screen that just sold somebody a seat — read aloud
  /// across a counter and typed into a phone, so it is large, spaced and
  /// tabular. Never the display serif: Fraunces has no tabular set, and a
  /// booking code where the 1 is narrower than the 8 is a code people misread.
  TextStyle get codeHero => _base(30, 34, FontWeight.w700, tabular: true);

  /// The conductor's verdict, and anything else that has to be readable at
  /// arm's length in direct sun. Inter, never the serif.
  TextStyle get shout => _base(40, 42, FontWeight.w700);

  /// A weight change that actually moves the axis.
  ///
  /// `style.copyWith(fontWeight: ...)` leaves `fontVariations` alone, so on a
  /// variable font it changes nothing at all and the text renders at the
  /// weight it already was. That is a silent failure, and the sort that ends
  /// up described as "the design just looks flat".
  static TextStyle weight(TextStyle style, FontWeight weight) => style.copyWith(
    fontWeight: weight,
    fontVariations: [
      FontVariation('wght', weight.value.toDouble()),
      ...?style.fontVariations?.where((v) => v.axis != 'wght'),
    ],
  );

  TextStyle _base(
    double size,
    double height,
    FontWeight weight, {
    bool tabular = false,
  }) => TextStyle(
    fontFamily: family,
    fontSize: size,
    height: height / size,
    fontWeight: weight,
    // Both axes named explicitly. Flutter maps `fontWeight` onto `wght` on its
    // own in most paths, but not every one, and a weight that silently does
    // nothing on a variable font is the kind of bug that reads as "the design
    // just looks flat".
    fontVariations: [
      FontVariation('wght', weight.value.toDouble()),
      FontVariation('opsz', size.clamp(14, 32).toDouble()),
    ],
    color: _color,
    fontFeatures: tabular ? _tabular : null,
  );

  TextStyle _serif(
    double size,
    double height,
    FontWeight weight, {
    required double opsz,
  }) => TextStyle(
    fontFamily: displayFamily,
    fontSize: size,
    height: height / size,
    fontWeight: weight,
    // `SOFT` rounds the terminals — warmth without losing the serif. `WONK`
    // is Fraunces' own axis for its more characterful alternates; on at
    // display sizes, where somebody is meant to notice the type, and the
    // reason this face was chosen over a neutral one.
    fontVariations: [
      FontVariation('wght', weight.value.toDouble()),
      FontVariation('opsz', opsz),
      FontVariation('SOFT', 28),
      FontVariation('WONK', 1),
    ],
    letterSpacing: -0.4,
    color: _color,
  );
}
