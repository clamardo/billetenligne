import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// One option out of a few, chosen by tapping it.
///
/// Distinct from [KChip], which states a fact and cannot be pressed. This one
/// is a control, and that difference is the whole design:
///
///   * **48 dp of tap target, whatever the label is.** The same floor as
///     [KButton], for the same reason — one thumb, in a hurry, sometimes on a
///     moving coach. The visible pill is smaller than the target and centred
///     in it, so a row of chips reads as light without being hard to hit.
///   * **Selection is never colour alone.** The chosen chip is filled *and*
///     announces itself as selected to a screen reader; a row of chips where
///     only the hue differs is a row nobody can read in direct sun.
///   * **A chip never wraps.** It ellipsises, because a row of options that
///     grows a second line pushes the content the traveller came for off the
///     screen — and the labels here are translated, so any of them can be a
///     third longer than the one that was designed against.
final class KChoiceChip extends StatelessWidget {
  const KChoiceChip({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
    super.key,
  });

  final String label;
  final bool selected;

  /// Null disables the chip. Used while the list it reorders is in flight,
  /// so a second tap cannot ask for a third order.
  final VoidCallback? onPressed;

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final enabled = onPressed != null;

    final background = selected
        ? kilo.color.brandPrimary
        : kilo.color.surfaceBase;
    final foreground = selected
        ? kilo.color.onBrandPrimary
        : kilo.color.contentPrimary;
    final border = selected
        ? kilo.color.brandPrimary
        : kilo.color.borderSubtle;

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.all(kilo.radius.pill),
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          // The target, not the pill. `ConstrainedBox` on the outside and the
          // padding on the inside: the thumb gets 48 dp, the eye gets a chip.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(
              widthFactor: 1,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: kilo.space.s3,
                  vertical: kilo.space.s2,
                ),
                decoration: BoxDecoration(
                  color: background,
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.all(kilo.radius.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 16, color: foreground),
                      SizedBox(width: kilo.space.s1),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        style: kilo.text.label.copyWith(color: foreground),
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
