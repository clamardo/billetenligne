import 'package:flutter/widgets.dart';

/// Inter, bundled and subset to Latin + French diacritics. Never fetched at
/// runtime — a font that arrives over 2G is a font the user watches arrive.
///
/// **Tabular figures are mandatory** on every price, time, seat number,
/// countdown and reference code. Amounts that shift width as digits change
/// look untrustworthy, and this app is made entirely of numbers people care
/// about.
@immutable
final class KiloTypography {
  const KiloTypography(this._color);
  final Color _color;

  static const family = 'Inter';

  /// Tabular figures. The single most important typographic decision here.
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  TextStyle get display => _base(32, 38, FontWeight.w700);
  TextStyle get h1 => _base(26, 32, FontWeight.w700);
  TextStyle get h2 => _base(21, 28, FontWeight.w600);
  TextStyle get h3 => _base(18, 24, FontWeight.w600);
  TextStyle get bodyLg => _base(17, 26, FontWeight.w400);
  TextStyle get body => _base(15, 22, FontWeight.w400);
  TextStyle get bodySm => _base(13, 18, FontWeight.w400);
  TextStyle get caption => _base(12, 16, FontWeight.w400);

  TextStyle get label =>
      _base(13, 16, FontWeight.w600).copyWith(letterSpacing: 0.4);

  TextStyle get amountHero => _base(30, 34, FontWeight.w700, tabular: true);
  TextStyle get amount => _base(17, 22, FontWeight.w600, tabular: true);
  TextStyle get amountSm => _base(14, 18, FontWeight.w500, tabular: true);

  /// Booking references, OTP, the rotating ticket code.
  TextStyle get code =>
      _base(16, 20, FontWeight.w600, tabular: true).copyWith(letterSpacing: 2);

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
    color: _color,
    fontFeatures: tabular ? _tabular : null,
  );
}
