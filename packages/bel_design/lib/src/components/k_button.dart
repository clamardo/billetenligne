import 'package:flutter/material.dart';

import '../kilo_theme.dart';

enum KButtonTone {
  /// The one action this screen exists for. At most one per screen.
  primary,

  /// Reversible, secondary. Outlined rather than filled.
  secondary,

  /// Tertiary. No border, no fill.
  ghost,

  /// Destructive and hard to undo. Never the default focus.
  danger,
}

/// The Kilo button.
///
/// Three things here are not negotiable, and each is a rule from the design
/// system rather than a preference:
///
///   * **48 dp minimum height, always.** Pressed with one thumb, in a hurry,
///     on a moving coach, sometimes by someone holding a child.
///   * **Loading replaces the label with a spinner and keeps the width.** A
///     button that shrinks mid-tap moves the thing underneath it into the
///     place your thumb is already heading.
///   * **A disabled button still says why.** [disabledHint] renders beneath
///     it, because a greyed control with no explanation is the single most
///     common way an app strands somebody.
final class KButton extends StatelessWidget {
  const KButton({
    required this.label,
    required this.onPressed,
    this.tone = KButtonTone.primary,
    this.icon,
    this.loading = false,
    this.fullWidth = true,
    this.disabledHint,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final KButtonTone tone;
  final IconData? icon;
  final bool loading;
  final bool fullWidth;

  /// Shown under a disabled button. Never null by accident: if a control is
  /// unavailable, the reason is part of the design.
  final String? disabledHint;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final (background, foreground, border) = _palette(kilo);

    final button = Semantics(
      button: true,
      enabled: _enabled,
      label: label,
      child: Material(
        color: _enabled ? background : kilo.color.surfaceSunken,
        borderRadius: kilo.radius.controlBorder,
        child: InkWell(
          onTap: _enabled ? onPressed : null,
          borderRadius: kilo.radius.controlBorder,
          child: Container(
            constraints: BoxConstraints(minHeight: kilo.space.touchTarget),
            padding: EdgeInsets.symmetric(horizontal: kilo.space.s5),
            decoration: BoxDecoration(
              borderRadius: kilo.radius.controlBorder,
              border: border == null
                  ? null
                  : Border.all(
                      color: _enabled ? border : kilo.color.borderSubtle,
                    ),
            ),
            child: Row(
              mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(foreground),
                    ),
                  )
                else ...[
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: _tint(kilo, foreground)),
                    SizedBox(width: kilo.space.s2),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: kilo.text.h3.copyWith(
                        color: _tint(kilo, foreground),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (disabledHint == null || _enabled) return button;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        SizedBox(height: kilo.space.s2),
        Text(
          disabledHint!,
          textAlign: TextAlign.center,
          style: kilo.text.bodySm.copyWith(color: kilo.color.contentSecondary),
        ),
      ],
    );
  }

  Color _tint(KiloTheme kilo, Color foreground) =>
      _enabled ? foreground : kilo.color.contentMuted;

  (Color, Color, Color?) _palette(KiloTheme kilo) => switch (tone) {
    KButtonTone.primary => (
      kilo.color.brandPrimary,
      kilo.color.onBrandPrimary,
      null,
    ),
    KButtonTone.secondary => (
      kilo.color.surfaceRaised,
      kilo.color.contentPrimary,
      kilo.color.borderStrong,
    ),
    KButtonTone.ghost => (
      // Transparent would let a sunken surface show through and drop the
      // label's contrast below the gate on the one screen that runs outdoors.
      kilo.color.surfaceBase,
      kilo.color.brandPrimary,
      null,
    ),
    KButtonTone.danger => (kilo.color.danger, kilo.color.contentInverse, null),
  };
}
