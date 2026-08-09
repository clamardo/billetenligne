import '../shared/failure.dart';
import '../shared/result.dart';

final class InvalidBookingRef extends DomainFailure {
  const InvalidBookingRef(this.reason);
  final String reason;
  @override
  String get code => 'booking.invalid_ref';
  @override
  Map<String, Object?> get params => {'reason': reason};
  @override
  String toString() => 'InvalidBookingRef($reason)';
}

/// A short, human-readable booking reference.
///
/// Read aloud over a bad phone line, typed by a station agent, written on a
/// paper manifest, and printed inside a 300-byte QR payload — so it uses
/// **Crockford base32**, which drops the four characters people confuse
/// (I, L, O, U) and treats the remaining ambiguous ones as aliases on input.
///
/// Six characters gives ~1.07 billion values. Generation is random, not
/// sequential: a sequential reference leaks daily volume to competitors and
/// lets anyone enumerate other people's bookings.
final class BookingRef {
  const BookingRef._(this.value);

  /// Canonical uppercase form, six characters.
  final String value;

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const length = 6;

  /// What a human typed, normalised: lowercase accepted, the `BEL-` prefix
  /// stripped, spaces and hyphens ignored, and O/I/L folded onto 0/1.
  static Result<BookingRef, InvalidBookingRef> parse(String input) {
    var s = input.toUpperCase().trim();
    if (s.startsWith('BEL-')) s = s.substring(4);
    s = s.replaceAll(RegExp(r'[\s\-]'), '');

    // Crockford's confusable aliases.
    s = s
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('U', 'V');

    if (s.isEmpty) return const Err(InvalidBookingRef('empty'));
    if (s.length != length) return const Err(InvalidBookingRef('length'));
    for (final ch in s.split('')) {
      if (!_alphabet.contains(ch)) {
        return const Err(InvalidBookingRef('charset'));
      }
    }
    return Ok(BookingRef._(s));
  }

  /// Builds a reference from an already-validated source (the database, or a
  /// verified ticket payload). Throws on malformed input, because a bad value
  /// here means our own data is corrupt.
  factory BookingRef.trusted(String value) {
    final parsed = parse(value);
    return switch (parsed) {
      Ok(:final value) => value,
      Err(:final failure) => throw ArgumentError(
        'corrupt booking ref "$value": $failure',
      ),
    };
  }

  /// Generates from a source of randomness supplied by the caller, so
  /// generation is deterministic under test.
  factory BookingRef.generate(int Function(int max) nextInt) {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(_alphabet[nextInt(_alphabet.length)]);
    }
    return BookingRef._(buffer.toString());
  }

  /// How it is shown to a traveller and printed on a ticket.
  String get display => 'BEL-$value';

  @override
  bool operator ==(Object other) => other is BookingRef && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => display;
}
