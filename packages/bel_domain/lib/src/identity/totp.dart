import 'dart:typed_data';

import '../ticketing/crypto_ports.dart';

/// RFC 6238 time-based one-time passwords, for back-office sign-in.
///
/// Deliberately **not** the same thing as `RotatingCode`, which also produces
/// six digits every thirty seconds. That one is ours end to end: our secret,
/// our app, HMAC-SHA256 because nothing else has to agree with us. This one
/// has to be readable by Google Authenticator, Aegis and 1Password, and those
/// read RFC 6238 as it was actually deployed: **HMAC-SHA1**, a base32 secret,
/// an eight-byte big-endian counter. Choosing SHA-256 here would be choosing
/// a stronger primitive that no authenticator app on a reviewer's phone can
/// compute, which is not a stronger control.
///
/// SHA-1 is broken for collision resistance and that is not what is used
/// here: HMAC-SHA1 has no practical break, and the value it protects lives
/// for thirty seconds.
final class Totp {
  const Totp._();

  static const digits = 6;
  static const periodSeconds = 30;

  /// One window either side. Back-office staff sit at desks with synchronised
  /// clocks, so the ±90 s a conductor's handset needs would be generosity
  /// bought with three times the guessing surface.
  static const toleranceWindows = 1;

  /// 160 bits, which is what RFC 4226 §4 requires and what every
  /// authenticator app expects to scan.
  static const secretBytes = 20;

  static int windowAt(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ periodSeconds;

  /// The code for one counter value.
  static String compute({
    required List<int> secret,
    required int counter,
    required MessageAuthenticator mac,
  }) {
    final message = Uint8List(8);
    var remaining = counter;
    for (var i = 7; i >= 0; i--) {
      message[i] = remaining & 0xff;
      remaining >>= 8;
    }

    final digest = mac.hmacSha1(key: secret, message: message);

    // RFC 4226 dynamic truncation, the same shape `RotatingCode` uses: an
    // offset from the last nibble, four bytes read there, sign bit masked.
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

  /// The window a presented code belongs to, or null if it belongs to none.
  ///
  /// Returns the *window* rather than a bool, and that is the whole reason
  /// this signature exists: the caller has to record which window was spent,
  /// so the same code cannot be replayed inside its own thirty seconds by
  /// somebody reading it over a shoulder. A boolean would make that
  /// impossible to implement correctly.
  ///
  /// Compared in constant time. A comparison that returns early on the first
  /// wrong digit turns a million-guess search into ten.
  static int? windowOf({
    required String presented,
    required List<int> secret,
    required DateTime now,
    required MessageAuthenticator mac,
    int tolerance = toleranceWindows,
  }) {
    final trimmed = presented.trim();
    if (trimmed.length != digits) return null;

    final centre = windowAt(now);
    int? matched;

    // Every candidate is evaluated: bailing on the first match would leak,
    // through timing, how far out of step the presenter's clock is.
    for (var offset = -tolerance; offset <= tolerance; offset++) {
      final window = centre + offset;
      final expected = compute(secret: secret, counter: window, mac: mac);
      if (_constantTimeEquals(expected, trimmed)) matched = window;
    }
    return matched;
  }

  /// What an authenticator app scans.
  ///
  /// The label carries the issuer twice — once as the prefix, once as the
  /// parameter — because that is what actually renders a readable entry
  /// across the three apps people have.
  static String provisioningUri({
    required String secretBase32,
    required String account,
    String issuer = 'BilletEnLigne',
  }) {
    final label = Uri.encodeComponent('$issuer:$account');
    final query = <String, String>{
      'secret': secretBase32,
      'issuer': issuer,
      'algorithm': 'SHA1',
      'digits': '$digits',
      'period': '$periodSeconds',
    };
    final encoded = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return 'otpauth://totp/$label?$encoded';
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

/// Base32, RFC 4648, no padding — the alphabet every authenticator app reads.
///
/// Written here rather than pulled in, for the same reason the rest of this
/// package has no dependencies: it is thirty lines, and the domain has to
/// compile into a server, a phone and a browser.
final class Base32 {
  const Base32._();

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static String encode(List<int> bytes) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;

    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(buffer >> (bits - 5)) & 0x1f]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 0x1f]);
    return out.toString();
  }

  /// Tolerant on input: padding, spaces and lower case are all things a human
  /// types when an app asks them to enter a key by hand.
  static List<int>? decode(String encoded) {
    final cleaned = encoded
        .toUpperCase()
        .replaceAll(RegExp(r'[\s=]'), '');

    final out = <int>[];
    var buffer = 0;
    var bits = 0;

    for (final unit in cleaned.codeUnits) {
      final value = _alphabet.indexOf(String.fromCharCode(unit));
      if (value < 0) return null;
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        out.add((buffer >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return out;
  }
}
