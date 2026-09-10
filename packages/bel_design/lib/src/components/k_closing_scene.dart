import 'package:flutter/material.dart';

import '../art/kilo_art.dart';
import '../kilo_theme.dart';

/// The panel a short screen ends on, filling whatever its content left over.
///
/// **Why a screen needs one.** A form that runs out two thirds of the way
/// down a handset leaves a field of bare cream between itself and the action
/// bar, and that gap reads as a page that failed to load rather than as a
/// page that is simply short. The results list has closed on an illustrated
/// panel since it was written; this is that panel, lifted out so every screen
/// can end the same way:
///
/// > *"no screen is meant to be all white and some small header background
/// > and nothing at the footer, you need to keep consistency regardless of
/// > the screen of the app."*
///
/// **Put it in a `SliverFillRemaining(hasScrollBody: false)`.** That hands
/// this widget tight constraints covering exactly the gap, and tight
/// constraints beat the [minHeight] below — so the panel is as tall as the
/// space it is closing on every handset, without measuring anything, and
/// collapses to nothing more than its floor when the content already fills
/// the screen.
///
/// Not a `LayoutBuilder`: that cannot report an intrinsic height, and
/// `hasScrollBody: false` asks for one. A list rendered as a blank page when
/// it did.
final class KClosingScene extends StatelessWidget {
  const KClosingScene({
    required this.art,
    this.caption,
    this.action,
    this.minHeight = 180,
    super.key,
  });

  final KSceneArt art;

  /// One line over the drawing. Null leaves the picture to speak.
  final String? caption;

  /// An optional control under the caption, sized to its own words — a
  /// full-width button at the foot of a page reads as the thing the page is
  /// for, and this panel is never that thing.
  final Widget? action;

  /// A floor, not the answer. See the class comment.
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        kilo.space.s4,
        kilo.space.s4,
        kilo.space.s4,
        kilo.space.s4,
      ),
      child: ClipRRect(
        borderRadius: kilo.radius.cardBorder,
        child: KScene(
          art,
          height: minHeight,
          overlay: true,
          // A scrim under the words, not a wash over the picture. `overlay`
          // dims the drawing evenly, which is not the same as making one
          // sentence readable: the coach's own body is the palest band in
          // these scenes, and light ink laid across it disappears exactly
          // where the sentence sits.
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.45, 1],
                colors: [
                  kilo.color.brandPrimaryStrong.withValues(alpha: 0),
                  kilo.color.brandPrimaryStrong.withValues(alpha: 0.95),
                ],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(kilo.space.s4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (caption != null)
                    Text(
                      caption!,
                      style: kilo.text.body.copyWith(
                        color: kilo.color.onBrandPrimary,
                      ),
                    ),
                  if (action != null) ...[
                    if (caption != null) SizedBox(height: kilo.space.s3),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: action,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
