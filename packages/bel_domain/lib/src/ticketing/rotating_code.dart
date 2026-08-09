import 'dart:convert';

import 'crypto_ports.dart';

/// The six digits under the QR that change every 30 seconds.
///
/// A signature proves a ticket is authentic. It does not prove the person
/// holding it is the person who bought it — a screenshot of a friend's QR
/// still scans perfectly. **This is what kills that attack**: the code is
/// derived from a per-ticket secret and the current time window, so a
/// screenshot's code is frozen and therefore stale, while the real app's
/// refreshes every half minute.
///
/// A screenshot still *scans*. It fails the freshness check, and the conductor
/// is prompted to ask the passenger to refresh — amber, not red, because the
/// far more common cause is a slow phone, not a fraudster.
final class RotatingCode {
  const RotatingCode._();

  static const windowSeconds = 30;
  static const digits = 6;

  /// How far out of step a device may be and still board people.
  ///
  /// Three windows either side. Cheap handsets drift, conductors work in dead
  /// zones where NTP never runs, and refusing a valid passenger because our
  /// clock disagreed is the worse failure by a wide margin.
  static const toleranceWindows = 3;

  static int windowAt(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ windowSeconds;

  /// The code for one specific window.
  static String compute({
    required List<int> secret,
    required int window,
    required MessageAuthenticator mac,
  }) {
    final digest = mac.hmacSha256(key: secret, message: utf8.encode('$window'));

    // RFC 4226 dynamic truncation: take an offset from the last nibble, read
    // four bytes there, mask the sign bit. Using a fixed offset would leak
    // more of the digest across observations.
    final offset = digest[digest.length - 1] & 0x0f;
    final binary =
        ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);

    var modulus = 1;
    for (var i = 0; i < digits; i++) {
      modulus *= 10;
    }
    return (binary % modulus).toString().padLeft(digits, '0');
  }

  /// What the traveller's phone shows right now.
  static String current({
    required List<int> secret,
    required DateTime now,
    required MessageAuthenticator mac,
  }) => compute(secret: secret, window: windowAt(now), mac: mac);

  /// Seconds until the displayed code changes — drives the little progress
  /// ring on the ticket, so the traveller can see it is live.
  static int secondsRemaining(DateTime now) =>
      windowSeconds -
      (now.toUtc().millisecondsSinceEpoch ~/ 1000 % windowSeconds);

  /// Whether a presented code is fresh enough to board on.
  ///
  /// Compared in constant time over the candidate windows: a timing oracle
  /// here would let someone brute-force a code digit by digit, and the check
  /// is cheap enough that there is no reason to be careless.
  static bool isFresh({
    required String presented,
    required List<int> secret,
    required DateTime now,
    required MessageAuthenticator mac,
    int tolerance = toleranceWindows,
  }) {
    if (presented.length != digits) return false;

    final centre = windowAt(now);
    var matched = false;
    for (var offset = -tolerance; offset <= tolerance; offset++) {
      final candidate = compute(
        secret: secret,
        window: centre + offset,
        mac: mac,
      );
      matched = _constantTimeEquals(candidate, presented) || matched;
    }
    return matched;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
