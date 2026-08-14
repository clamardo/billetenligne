import '../shared/failure.dart';
import '../shared/result.dart';

final class InvalidEmailAddress extends DomainFailure {
  const InvalidEmailAddress(this.reason);
  final String reason;
  @override
  String get code => 'email.invalid';
  @override
  Map<String, Object?> get params => {'reason': reason};
  @override
  String toString() => 'InvalidEmailAddress($reason)';
}

/// A validated address, stored canonically in lower case.
///
/// The validation is deliberately shallow — one `@`, something either side, a
/// dot in the domain — because the only test of an email address that means
/// anything is sending to it and being answered, which is exactly what the
/// sign-in code does. A stricter regex here would reject valid addresses
/// (apostrophes, plus tags, new TLDs) and still not prove the mailbox exists.
///
/// The normalisation is the part that carries weight. `Serge@Example.CG` and
/// `serge@example.cg` are one mailbox, and treating them as two means two
/// accounts, two ticket histories, and a traveller certain we lost their
/// booking. Migration 0007's unique index on `lower(email)` is the same rule
/// stated where it cannot be bypassed.
final class EmailAddress {
  const EmailAddress._(this.value, this.domain);

  /// Lowercased and trimmed. This is what is stored and what the rate limit
  /// keys on.
  final String value;

  final String domain;

  /// `c***t@gmail.com` — enough for the traveller to recognise the address
  /// they typed, not enough for a stranger holding their unlocked phone to
  /// read one off the screen.
  String get masked {
    final local = value.substring(0, value.indexOf('@'));
    if (local.length <= 2) return '${local[0]}***@$domain';
    return '${local[0]}***${local[local.length - 1]}@$domain';
  }

  static Result<EmailAddress, InvalidEmailAddress> parse(String input) {
    final trimmed = input.trim().toLowerCase();
    if (trimmed.isEmpty) return const Err(InvalidEmailAddress('empty'));

    // A length cap, because the address is a database key and a rate-limit
    // key, and an unbounded one is a cheap way to make both expensive.
    if (trimmed.length > 254) return const Err(InvalidEmailAddress('length'));

    final at = trimmed.indexOf('@');
    if (at <= 0 || at != trimmed.lastIndexOf('@')) {
      return const Err(InvalidEmailAddress('format'));
    }

    final domain = trimmed.substring(at + 1);
    if (domain.length < 3 ||
        !domain.contains('.') ||
        domain.startsWith('.') ||
        domain.endsWith('.')) {
      return const Err(InvalidEmailAddress('domain'));
    }

    if (trimmed.contains(' ')) return const Err(InvalidEmailAddress('format'));

    return Ok(EmailAddress._(trimmed, domain));
  }

  @override
  bool operator ==(Object other) =>
      other is EmailAddress && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}
