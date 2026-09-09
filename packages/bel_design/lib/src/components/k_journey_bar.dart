import 'package:flutter/material.dart';

import '../art/kilo_pattern.dart';
import '../kilo_theme.dart';

/// The header a traveller sees while they are buying: a woven band in the
/// brand's own green, with the journey written on it.
///
/// **Why a band and not a white bar.** Every screen after the home hero used
/// Material's default surface, so the moment a search returned anything the
/// product stopped looking like itself — a white list under a white bar, with
/// the only brand on screen three taps behind. The hero already proves the
/// artwork carries at this size; this is the same idea at the height a
/// working screen can afford.
///
/// **A real `AppBar` underneath.** The motif is painted into `flexibleSpace`
/// rather than replacing the bar, so the back button keeps its semantics and
/// its 48 dp target, the title keeps its heading role for a screen reader,
/// and scroll-under behaviour is Material's rather than ours.
///
/// The motif is geometry (`KPattern`), not an asset: it tiles at any width,
/// stays crisp at any density, and costs no bytes and no request — which is
/// what lets a header exist at all under ADR-0009's budget.
final class KJourneyBar extends StatelessWidget implements PreferredSizeWidget {
  const KJourneyBar({
    required this.title,
    this.subtitle,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.actions,
    this.motif = KPatternMotif.kuba,
    super.key,
  });

  final String title;

  /// The line under the title — the date and how many coaches, the company
  /// and the hour. Drawn at 82% of the band's ink rather than in a second
  /// colour: a header with two inks on a patterned ground is one where
  /// neither reads.
  final String? subtitle;

  final Widget? leading;

  /// False on the screens a traveller must not reverse out of by the bar —
  /// a seat is held on a countdown, and a booking is already paid for.
  final bool automaticallyImplyLeading;

  final List<Widget>? actions;
  final KPatternMotif motif;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 12);

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final ink = kilo.color.onBrandPrimary;

    // A back button already supplies the gutter, so the title follows it with
    // no gap. With nothing to its left — "Your seat is reserved", which a
    // traveller must not reverse out of — a zero here puts the heading hard
    // against the screen edge, and the band reads as a mistake rather than a
    // header.
    final hasLeading =
        leading != null ||
        (automaticallyImplyLeading && Navigator.canPop(context));

    return AppBar(
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      actions: actions,
      titleSpacing: hasLeading ? 0 : kilo.space.s4,
      toolbarHeight: preferredSize.height,
      backgroundColor: kilo.color.brandPrimary,
      foregroundColor: ink,
      elevation: 0,
      // The ink is fixed to the brand's own, so the pattern cannot make the
      // title unreadable: `onBrandPrimary` is the pair the contrast gate
      // checks, and the motif is drawn at a low opacity of that same ink
      // rather than of an arbitrary colour.
      // `SizedBox.expand` is load-bearing: `KPattern` sizes itself to its
      // child, and a `CustomPaint` with neither a child nor a size collapses
      // to nothing — the band renders as flat colour and the motif is
      // silently absent. Giving it something that fills the constraints is
      // what makes the paint have a surface to happen on.
      flexibleSpace: KPattern(
        motif: motif,
        background: kilo.color.brandPrimary,
        color: ink,
        opacity: 0.16,
        child: const SizedBox.expand(),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: kilo.text.h3.copyWith(color: ink)),
          if (subtitle != null)
            Text(
              subtitle!,
              style: kilo.text.caption.copyWith(
                color: ink.withValues(alpha: 0.82),
              ),
            ),
        ],
      ),
    );
  }
}
