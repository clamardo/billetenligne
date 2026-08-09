import 'dart:async';

import 'package:flutter/material.dart';

import '../kilo_theme.dart';

/// The hold countdown.
///
/// The most emotionally loaded element in the product: it is the thing telling
/// somebody how long they have to find their PIN before their seat goes back
/// on sale. Four decisions follow from that:
///
///   * **It counts down from an instant, not a duration.** A slow response
///     must not make the timer lie — the server sent an expiry, and this
///     renders the truth about that expiry.
///   * **Amber only when it is genuinely urgent**, and red only at the very
///     end. Crying wolf on a countdown teaches people to ignore it, and this
///     is the one countdown they must not ignore.
///   * **Tabular figures.** A timer whose digits change width twitches, and a
///     twitching timer reads as panic.
///   * **It ticks once a second, and stops when it reaches zero.** A timer
///     still running at -00:07 is an app that has stopped paying attention.
final class KCountdown extends StatefulWidget {
  const KCountdown({
    required this.expiresAt,
    required this.labelBuilder,
    this.warnAt = const Duration(minutes: 2),
    this.criticalAt = const Duration(seconds: 30),
    this.onExpired,
    this.now = _systemNow,
    super.key,
  });

  final DateTime expiresAt;

  /// Builds the sentence around the time. The design system holds no
  /// user-facing prose; the app supplies it from the catalog.
  final String Function(Duration remaining) labelBuilder;

  final Duration warnAt;
  final Duration criticalAt;
  final VoidCallback? onExpired;

  /// Injectable, so the one moment that matters — reaching zero — can actually
  /// be tested. `tester.pump()` advances Flutter's timers but not the wall
  /// clock, so a component that reads `DateTime.now()` directly counts down
  /// forever in a test and its expiry callback is never verified. That
  /// callback releases a seat; leaving it unverified is not an option.
  final DateTime Function() now;

  @override
  State<KCountdown> createState() => _KCountdownState();
}

class _KCountdownState extends State<KCountdown> {
  Timer? _timer;
  late Duration _remaining;
  var _fired = false;

  @override
  void initState() {
    super.initState();
    _remaining = _left();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void didUpdateWidget(KCountdown old) {
    super.didUpdateWidget(old);
    // A refreshed hold moves the expiry. Recomputing rather than continuing to
    // count down from the old one is the difference between a timer and a
    // decoration.
    if (old.expiresAt != widget.expiresAt) {
      _fired = false;
      setState(() => _remaining = _left());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration _left() {
    final left = widget.expiresAt.difference(widget.now().toUtc());
    return left.isNegative ? Duration.zero : left;
  }

  void _tick() {
    final left = _left();
    if (mounted) setState(() => _remaining = left);

    if (left == Duration.zero && !_fired) {
      _fired = true;
      _timer?.cancel();
      widget.onExpired?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;

    final colour = _remaining <= widget.criticalAt
        ? kilo.color.danger
        : _remaining <= widget.warnAt
        ? kilo.color.warning
        : kilo.color.contentSecondary;

    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 16, color: colour),
          SizedBox(width: kilo.space.s2),
          Text(
            widget.labelBuilder(_remaining),
            style: kilo.text.amountSm.copyWith(color: colour),
          ),
        ],
      ),
    );
  }
}

DateTime _systemNow() => DateTime.now().toUtc();

/// `mm:ss`, zero-padded, monotonic width.
///
/// **Rounds up, deliberately.** With 1.99 seconds left you genuinely have two
/// seconds, and truncating shows 00:01 the instant the timer appears — so a
/// fifteen-minute hold opens at 14:59 and looks like it has already started
/// leaking. Rounding up also means 00:00 appears exactly when the hold
/// expires, rather than a second early.
String formatCountdown(Duration d) {
  final total = d.isNegative ? 0 : (d.inMilliseconds / 1000).ceil();
  final minutes = (total ~/ 60).toString().padLeft(2, '0');
  final seconds = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
