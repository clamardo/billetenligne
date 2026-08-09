import 'currency.dart';

/// Money is integer minor units plus a [Currency]. Never a `double`.
///
/// Cross-currency arithmetic throws rather than silently producing nonsense —
/// in practice it is caught in tests, because a single deployment never mixes
/// currencies within one booking.
final class Money implements Comparable<Money> {
  const Money(this.minor, this.currency);

  const Money.zero(this.currency) : minor = 0;

  /// Convenience for XAF, the launch currency (zero-decimal).
  const Money.xaf(this.minor) : currency = Currency.xaf;

  final int minor;
  final Currency currency;

  bool get isZero => minor == 0;
  bool get isPositive => minor > 0;
  bool get isNegative => minor < 0;

  Money operator +(Money other) => Money(minor + _checked(other), currency);
  Money operator -(Money other) => Money(minor - _checked(other), currency);
  Money operator -() => Money(-minor, currency);

  /// Multiply by a rate, rounding half-up — the convention travellers expect
  /// when they check our arithmetic against their own.
  Money multiply(num factor) => Money((minor * factor).round(), currency);

  /// Basis points: 500 bps = 5%. Commission is expressed this way to keep
  /// percentages out of floating point.
  Money percentBps(int bps) => Money((minor * bps / 10000).round(), currency);

  Money clampToZero() => minor < 0 ? Money.zero(currency) : this;

  bool operator >(Money other) => minor > _checked(other);
  bool operator <(Money other) => minor < _checked(other);
  bool operator >=(Money other) => minor >= _checked(other);
  bool operator <=(Money other) => minor <= _checked(other);

  @override
  int compareTo(Money other) => minor.compareTo(_checked(other));

  /// Split into [parts] shares using the largest-remainder method, so the
  /// shares always sum **exactly** back to this amount — no rounding dust
  /// left behind in a suspense account (`04-payments.md` §2).
  List<Money> allocate(List<int> weights) {
    if (weights.isEmpty) throw ArgumentError('weights must not be empty');
    final total = weights.fold<int>(0, (a, b) => a + b);
    if (total <= 0) throw ArgumentError('weights must sum to a positive value');

    final shares = <int>[];
    var allocated = 0;
    for (final w in weights) {
      final share = (minor * w) ~/ total;
      shares.add(share);
      allocated += share;
    }

    // Distribute the remainder to the largest fractional parts, in order.
    var remainder = minor - allocated;
    final order = List<int>.generate(weights.length, (i) => i)
      ..sort((a, b) {
        final fa = (minor * weights[a]) % total;
        final fb = (minor * weights[b]) % total;
        return fb.compareTo(fa);
      });
    var i = 0;
    while (remainder != 0 && weights.isNotEmpty) {
      final idx = order[i % order.length];
      shares[idx] += remainder > 0 ? 1 : -1;
      remainder += remainder > 0 ? -1 : 1;
      i++;
    }

    return shares.map((s) => Money(s, currency)).toList(growable: false);
  }

  /// Narrow no-break space (U+202F) — French thousands separator.
  static const narrowNbsp = '\u202F';

  /// No-break space (U+00A0) — sits between an amount and its symbol so a
  /// line break can never split "9 000" from "FCFA".
  static const nbsp = '\u00A0';

  /// Locale-aware formatting. Dependency-free on purpose (ADR-0001): the
  /// domain has no `intl`, and these two locales are the whole contract.
  ///
  ///   fr -> `9{U+202F}000{U+00A0}FCFA`
  ///   en -> `XAF 9,000`
  ///
  /// Separators are written as escapes, never as literal characters: an
  /// invisible U+202F in source is impossible to review and trivially
  /// mangled by an editor.
  String format({String locale = 'fr', bool withSymbol = true}) {
    final isFr = locale.startsWith('fr');
    final negative = minor < 0;
    final abs = minor.abs();

    final major = abs ~/ currency.minorPerMajor;
    final fraction = abs % currency.minorPerMajor;

    final groupSep = isFr ? narrowNbsp : ',';
    final digits = major.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(groupSep);
      buffer.write(digits[i]);
    }
    var text = buffer.toString();

    if (currency.exponent > 0) {
      final decimalSep = isFr ? ',' : '.';
      text =
          '$text$decimalSep${fraction.toString().padLeft(currency.exponent, '0')}';
    }

    if (withSymbol) {
      text = isFr
          ? '$text$nbsp${currency.symbol}'
          : (currency.symbolLeading
                ? '${currency.symbol}$text'
                : '${currency.code} $text');
    }

    return negative ? '\u2212$text' : text;
  }

  int _checked(Money other) {
    if (other.currency != currency) {
      throw ArgumentError('Currency mismatch: $currency vs ${other.currency}');
    }
    return other.minor;
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;
  @override
  int get hashCode => Object.hash(minor, currency);
  @override
  String toString() => format(locale: 'en');
}
