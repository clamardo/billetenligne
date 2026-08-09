import 'package:flutter/widgets.dart';

import '../kilo_theme.dart';

enum KMoneySize { hero, normal, small }

/// An amount, rendered by the design system rather than by a caller.
///
/// Exists so that no screen ever interpolates a price into a string. Two
/// things follow from that and neither is optional:
///
///   * **Tabular figures**, so 12 300 and 19 900 are the same width and a list
///     of prices lines up. Amounts that jitter as digits change look
///     untrustworthy, and this app is made of numbers people care about.
///   * **The locale decides the separators.** French uses a narrow no-break
///     space and a comma; English uses a comma and a full stop. XAF is
///     zero-decimal, which the domain already knows — nothing here guesses.
final class KMoney extends StatelessWidget {
  const KMoney(
    this.formatted, {
    this.size = KMoneySize.normal,
    this.color,
    this.strikethrough = false,
    super.key,
  });

  /// Already formatted by `Money.format(locale:)`. Passing a formatted string
  /// rather than a Money keeps `bel_design` free of business types — a
  /// component that knows the domain cannot be rendered in a gallery.
  final String formatted;

  final KMoneySize size;
  final Color? color;
  final bool strikethrough;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    final style = switch (size) {
      KMoneySize.hero => kilo.text.amountHero,
      KMoneySize.normal => kilo.text.amount,
      KMoneySize.small => kilo.text.amountSm,
    };

    return Text(
      formatted,
      style: style.copyWith(
        color: color,
        decoration: strikethrough ? TextDecoration.lineThrough : null,
      ),
      // Never wraps mid-amount. "12 300" broken across two lines reads as two
      // numbers.
      softWrap: false,
      overflow: TextOverflow.visible,
    );
  }
}
