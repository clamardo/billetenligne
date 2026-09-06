import 'package:flutter/material.dart';

import '../kilo_theme.dart';
import '../tokens/kilo_colors.dart';

enum KAvatarSize { small, normal, large }

/// A traveller, drawn without a photograph.
///
/// This product never asks anybody to upload one: a face is one more request
/// that can fail on 2G, one more thing to moderate, and one more asset this
/// design system would have to duplicate per theme. What it draws instead is
/// the same trick the rest of Kilo uses to stay alive without a network —
/// initials on a colour, both computed rather than fetched.
///
/// The colour is deterministic, not random: the same [seed] always lands on
/// the same [AccentHue], so a passenger's avatar looks the same on the ticket
/// screen as it did at sign-in, without anywhere persisting a colour choice.
final class KAvatar extends StatelessWidget {
  const KAvatar({
    required this.seed,
    this.label,
    this.size = KAvatarSize.normal,
    super.key,
  });

  /// What decides the colour — a name, a phone number, an account id.
  /// Anything stable for one person works; nothing here is read as PII.
  final String seed;

  /// What the initials are drawn from. Falls back to [seed] when a display
  /// name is not known yet, which still produces a legible glyph rather than
  /// a blank circle: a phone number's first digit beats nothing at all.
  final String? label;

  final KAvatarSize size;

  @override
  Widget build(BuildContext context) {
    final kilo = context.kilo;
    final diameter = switch (size) {
      KAvatarSize.small => 28.0,
      KAvatarSize.normal => 40.0,
      KAvatarSize.large => 64.0,
    };
    final hue = _hueOf(seed);

    return Semantics(
      label: label ?? seed,
      child: ExcludeSemantics(
        child: Container(
          width: diameter,
          height: diameter,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: hue.color, shape: BoxShape.circle),
          child: Text(
            _initialsOf(label ?? seed),
            style: kilo.text.label.copyWith(
              color: hue.ink,
              fontSize: diameter * 0.38,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }

  /// Stable across runs and across platforms: `String.hashCode` is not
  /// guaranteed either, so this sums code units rather than trusting it.
  static AccentHue _hueOf(String seed) {
    var sum = 0;
    for (final unit in seed.codeUnits) {
      sum = (sum + unit) % 0x7fffffff;
    }
    return AccentHue.values[sum % AccentHue.values.length];
  }

  static String _initialsOf(String text) {
    final words = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    final first = words.first.substring(0, 1).toUpperCase();
    if (words.length == 1) {
      // A phone number or a single name: the second glyph still says more
      // than one letter alone, and a lone digit reads as a placeholder.
      final word = words.first;
      return word.length < 2
          ? first
          : '$first${word.substring(1, 2).toUpperCase()}';
    }
    final last = words.last.substring(0, 1).toUpperCase();
    return '$first$last';
  }
}
