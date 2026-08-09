/// A currency and, critically, its exponent.
///
/// XAF (Congo-Brazzaville) and CDF are **zero-decimal**: 9 000 XAF is 9000
/// minor units, not 900 000. Getting this wrong is the classic African
/// fintech bug, so the exponent is data, never an assumption.
final class Currency {
  const Currency._(this.code, this.exponent, this.symbol, this.symbolLeading);

  final String code;
  final int exponent;
  final String symbol;
  final bool symbolLeading;

  static const xaf = Currency._('XAF', 0, 'FCFA', false);
  static const cdf = Currency._('CDF', 0, 'FC', false);
  static const usd = Currency._('USD', 2, r'$', true);
  static const eur = Currency._('EUR', 2, '€', false);

  static const all = <Currency>[xaf, cdf, usd, eur];

  static Currency? byCode(String code) {
    for (final c in all) {
      if (c.code == code.toUpperCase()) return c;
    }
    return null;
  }

  int get minorPerMajor {
    var factor = 1;
    for (var i = 0; i < exponent; i++) {
      factor *= 10;
    }
    return factor;
  }

  @override
  bool operator ==(Object other) => other is Currency && other.code == code;
  @override
  int get hashCode => code.hashCode;
  @override
  String toString() => code;
}
