import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// A raised surface with a border.
///
/// The border does the work, not the shadow. Soft shadows render badly and
/// cost fill-rate on the cheap GPUs this app targets, so a Kilo card still
/// reads correctly when its shadow is imperceptible — which, in direct
/// equatorial sun, it will be.
final class KCard extends StatelessWidget {
  const KCard({
    required this.child,
    this.onTap,
    this.padding,
    this.tone,
    this.borderColor,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;
  final Color? tone;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    final content = Container(
      padding: padding ?? EdgeInsets.all(kilo.space.s4),
      decoration: BoxDecoration(
        color: tone ?? kilo.color.surfaceRaised,
        borderRadius: kilo.radius.cardBorder,
        border: Border.all(color: borderColor ?? kilo.color.borderSubtle),
        boxShadow: kilo.elevation.raised,
      ),
      child: child,
    );

    if (onTap == null) return content;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: kilo.radius.cardBorder,
        child: content,
      ),
    );
  }
}
