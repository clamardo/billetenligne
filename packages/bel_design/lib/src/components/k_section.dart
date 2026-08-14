import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// A heading over a group of rows, with an optional count and an action.
///
/// Every list screen in the console and the back office had grown its own
/// version of this out of a `Text` and a `Spacer`, which is how six screens
/// end up with six spacings and four type sizes. It is one component now, and
/// the alternative to using it is a review comment.
final class KSectionHeader extends StatelessWidget {
  const KSectionHeader(
    this.title, {
    super.key,
    this.count,
    this.subtitle,
    this.action,
  });

  final String title;

  /// Drawn as a pill beside the heading. Null and zero are different: zero is
  /// worth saying out loud on a queue, and null means nobody counted.
  final int? count;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s3, top: kilo.space.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, style: kilo.text.h3)),
                    if (count != null) ...[
                      SizedBox(width: kilo.space.s2),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.all(kilo.radius.pill),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: kilo.space.s2,
                            vertical: 1,
                          ),
                          child: Text(
                            '$count',
                            style: kilo.text.caption.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  SizedBox(height: kilo.space.s1),
                  Text(
                    subtitle!,
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// The top of a screen: what this page is, what it is about, and the one
/// thing to do with it.
///
/// Separate from [KSectionHeader] because they are different jobs at
/// different sizes, and because the two back-office surfaces had drifted: the
/// console titled its pages in the body face at 21 and the back office used
/// the serif at 26, for the same role, on the same design system. One
/// component now, and it is the serif — `h1` is the display face, a page
/// title is the one place per screen it belongs, and a console whose every
/// heading is set in the same face as its table rows is a console where
/// nothing stands out. That was the complaint this whole pass exists to
/// answer.
final class KPageHeader extends StatelessWidget {
  const KPageHeader(
    this.title, {
    super.key,
    this.count,
    this.subtitle,
    this.action,
  });

  final String title;

  /// Drawn as a pill beside the title. Null and zero are different, the same
  /// as on [KSectionHeader]: zero pending payouts is worth saying, and null
  /// means nobody counted.
  final int? count;

  /// The line under the title. Usually the sentence that says what the list
  /// below is, which several screens were spacing themselves.
  final String? subtitle;

  /// The page's own action, if it has exactly one. More than one belongs on
  /// the rows, not up here.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(bottom: kilo.space.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: kilo.text.h1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (count != null) ...[
                      SizedBox(width: kilo.space.s3),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.all(kilo.radius.pill),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: kilo.space.s3,
                            vertical: 2,
                          ),
                          child: Text(
                            '$count',
                            style: kilo.text.body.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  SizedBox(height: kilo.space.s1),
                  Text(
                    subtitle!,
                    style: kilo.text.bodySm.copyWith(
                      color: kilo.color.contentSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// One figure and what it is.
///
/// The number is the point, so it is set in the tabular face at display size
/// and the label is small underneath — the other way round is a dashboard
/// where every tile reads as a sentence and none of the figures can be
/// scanned.
final class KStat extends StatelessWidget {
  const KStat({
    required this.value,
    required this.label,
    super.key,
    this.tone,
    this.icon,
  });

  final String value;
  final String label;

  /// A colour for the figure alone, never for its background: a tile that
  /// turns red is a tile somebody stops reading.
  final Color? tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: tone ?? kilo.color.contentMuted),
              SizedBox(width: kilo.space.s1),
            ],
            Text(
              value,
              style: kilo.text.amountHero.copyWith(
                color: tone ?? kilo.color.contentPrimary,
              ),
            ),
          ],
        ),
        SizedBox(height: kilo.space.s1),
        Text(
          label,
          style: kilo.text.label.copyWith(color: kilo.color.contentSecondary),
        ),
      ],
    );
  }
}

/// The shape of the thing that is loading, in the colour of the page.
///
/// A spinner says *something is happening*; this says *a list of four rows is
/// about to be here*, which on a connection where the difference is six
/// seconds is the difference between waiting and leaving. Never used for a
/// wait that might end in an empty list — a skeleton that resolves to
/// "nothing found" has told somebody a lie for six seconds.
final class KSkeleton extends StatefulWidget {
  const KSkeleton({
    super.key,
    this.height = 14,
    this.width,
    this.radius,
    this.animate = true,
  });

  /// A stack of [rows] card-shaped blocks, for a list that is loading.
  static Widget list({int rows = 3, double height = 76}) =>
      _SkeletonList(rows: rows, height: height);

  final double height;
  final double? width;
  final Radius? radius;
  final bool animate;

  @override
  State<KSkeleton> createState() => _KSkeletonState();
}

class _KSkeletonState extends State<KSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final scheme = Theme.of(context).colorScheme;
    // Respects the platform's reduce-motion setting, and stops pulsing on a
    // cheap device where the repaint is a battery tax paid by the poorest
    // user (`05-design-system.md` §8).
    final still = !widget.animate || MediaQuery.disableAnimationsOf(context);

    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.all(widget.radius ?? kilo.radius.sm),
      ),
      child: SizedBox(height: widget.height, width: widget.width),
    );

    if (still) return box;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.6, end: 1).animate(_pulse),
      child: box,
    );
  }
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList({required this.rows, required this.height});
  final int rows;
  final double height;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    return Column(
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: EdgeInsets.only(bottom: kilo.space.s3),
            child: KSkeleton(height: height, radius: kilo.radius.lg),
          ),
      ],
    );
  }
}
