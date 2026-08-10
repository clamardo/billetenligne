import 'dart:convert';

import 'package:bel_domain/bel_domain.dart';

/// Wire encoding helpers.
///
/// Serialisation is **hand-written**, not generated. The wire format is the
/// contract between four clients and a server, and it deserves to be read
/// directly rather than inferred from annotations — and `Money`, enums and
/// nullable timestamps all need custom handling anyway. The cost is some
/// boilerplate; the benefit is that nobody has to run a code generator to
/// understand what goes over the network.
final class Wire {
  const Wire._();

  /// Money is `{"minor": 9300, "currency": "XAF"}`.
  ///
  /// **Never a float, never a pre-formatted string.** A float loses exactness
  /// and a formatted string forces the server to guess the reader's locale —
  /// formatting belongs to the surface that renders it (ADR-0008).
  static Map<String, Object?> money(Money m) => {
    'minor': m.minor,
    'currency': m.currency.code,
  };

  static Money readMoney(Object? raw, {String field = 'amount'}) {
    final map = _requireMap(raw, field);
    final minor = map['minor'];
    if (minor is! int) {
      throw WireFormatException(
        field,
        'minor must be an integer number of minor units, got ${minor.runtimeType}',
      );
    }
    final code = _requireString(map['currency'], '$field.currency');
    final currency = Currency.byCode(code);
    if (currency == null) {
      throw WireFormatException('$field.currency', 'unknown currency "$code"');
    }
    return Money(minor, currency);
  }

  /// Timestamps are always UTC ISO-8601 with a `Z`. Local time on the wire is
  /// how a departure ends up an hour out.
  static String instant(DateTime d) => d.toUtc().toIso8601String();

  static DateTime readInstant(Object? raw, {String field = 'timestamp'}) {
    final s = _requireString(raw, field);
    final parsed = DateTime.tryParse(s);
    if (parsed == null) {
      throw WireFormatException(field, 'not an ISO-8601 timestamp: "$s"');
    }
    return parsed.toUtc();
  }

  static DateTime? readInstantOrNull(
    Object? raw, {
    String field = 'timestamp',
  }) => raw == null ? null : readInstant(raw, field: field);

  /// Durations travel as whole seconds. Enough resolution for a hold
  /// countdown, and unambiguous across languages.
  /// Raw bytes on the wire: standard base64, because JSON has no byte type
  /// and hex would cost twice the bytes on a metered prepaid bundle.
  ///
  /// Used for the ticket's rotating secret, which is the only binary this API
  /// hands to a client — and it hands it to exactly one device, over a
  /// response marked `private, no-store`.
  static String bytes(List<int> raw) => base64.encode(raw);

  static List<int> readBytes(Object? raw, {String field = 'bytes'}) {
    final text = requireString(raw, field);
    try {
      return base64.decode(text);
    } on FormatException catch (e) {
      throw WireFormatException(field, 'is not base64: ${e.message}');
    }
  }

  static int seconds(Duration d) => d.inSeconds;

  static Duration readSeconds(Object? raw, {String field = 'duration'}) {
    if (raw is! int) {
      throw WireFormatException(field, 'expected seconds as an integer');
    }
    return Duration(seconds: raw);
  }

  /// Enums travel as their `name`, never their index — an index reorders
  /// silently when someone inserts a value, and takes production with it.
  static T readEnum<T extends Enum>(
    Object? raw,
    List<T> values, {
    required String field,
    T? fallback,
  }) {
    final s = _requireString(raw, field);
    for (final v in values) {
      if (v.name == s) return v;
    }
    if (fallback != null) return fallback;
    throw WireFormatException(field, 'unknown value "$s"');
  }

  static String requireString(Object? raw, String field) =>
      _requireString(raw, field);

  static int requireInt(Object? raw, String field) {
    if (raw is! int) {
      throw WireFormatException(field, 'expected an integer');
    }
    return raw;
  }

  static Map<String, Object?> requireMap(Object? raw, String field) =>
      _requireMap(raw, field);

  static List<T> readList<T>(
    Object? raw,
    T Function(Map<String, Object?>) item, {
    required String field,
  }) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw WireFormatException(field, 'expected a list');
    }
    return [
      for (var i = 0; i < raw.length; i++)
        item(_requireMap(raw[i], '$field[$i]')),
    ];
  }

  /// Drops null-valued keys. Absent and null mean the same thing to every
  /// client, and omitting them is meaningfully fewer bytes on a metered
  /// prepaid bundle (ADR-0003).
  static Map<String, Object?> compact(Map<String, Object?> map) {
    final out = <String, Object?>{};
    for (final e in map.entries) {
      if (e.value != null) out[e.key] = e.value;
    }
    return out;
  }

  static String _requireString(Object? raw, String field) {
    if (raw is! String) {
      throw WireFormatException(field, 'expected a string');
    }
    return raw;
  }

  static Map<String, Object?> _requireMap(Object? raw, String field) {
    if (raw is! Map) {
      throw WireFormatException(field, 'expected an object');
    }
    return raw.cast<String, Object?>();
  }
}

/// Thrown when the wire format is violated.
///
/// Names the field, because "type 'Null' is not a subtype of type 'String'"
/// in a production log tells you nothing about which endpoint broke.
final class WireFormatException implements Exception {
  const WireFormatException(this.field, this.message);
  final String field;
  final String message;

  @override
  String toString() => 'WireFormatException($field): $message';
}
