import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// The bar a screen ends on.
///
/// **Why every funnel screen needs one.** A screen that opens on a woven band
/// and then stops halfway down the handset is a screen that has a header and
/// no shape — and the funnel had fourteen of them. The seat map has closed
/// itself with a summary bar since it was written, the results list closes
/// with an illustrated panel, and everything between the two simply ran out.
/// Reported plainly:
///
/// > *"no screen is meant to be all white and some small header background
/// > and nothing at the footer, you need to keep consistency regardless of
/// > the screen of the app."*
///
/// So this is the seat map's bar, lifted out and made shared: a raised
/// surface, a hairline above it, the floating shadow, and the safe area
/// honoured so the action never sits under a gesture bar.
///
/// It is deliberately not a slot for anything. A funnel screen has one thing
/// it wants next, and putting that one thing in a fixed place on every screen
/// is most of what "the experience is the same" means to somebody thumbing
/// through a purchase.
final class KActionBar extends StatelessWidget {
  const KActionBar({required this.child, this.above, super.key});

  /// The action itself — normally one [KButton].
  final Widget child;

  /// What sits over the action: a total, a countdown, a line of reassurance.
  /// Null on the screens where the action needs no gloss.
  final Widget? above;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    return Container(
      decoration: BoxDecoration(
        color: kilo.color.surfaceRaised,
        border: Border(top: BorderSide(color: kilo.color.borderSubtle)),
        boxShadow: kilo.elevation.floating,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.all(kilo.space.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (above != null) ...[above!, SizedBox(height: kilo.space.s3)],
              child,
            ],
          ),
        ),
      ),
    );
  }
}
