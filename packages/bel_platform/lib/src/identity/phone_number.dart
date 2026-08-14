import '../market/payment_rail.dart';
import '../shared/failure.dart';
import '../shared/result.dart';

/// MSISDN prefix to carrier. Deliberately **data**, not a `switch`.
///
/// ADR-0005: "exact ranges live in configuration, not code, because operators
/// renumber". This table is the compiled-in default; the server overrides it
/// from config so a renumbering is a config push, not an app release — and a
/// new country is a new table, not a new branch.
final class MsisdnPrefixTable {
  const MsisdnPrefixTable(this.countryCode, this.nationalLength, this.prefixes);

  final String countryCode;
  final int nationalLength;
  final Map<String, MobileOperator> prefixes;

  /// Republic of Congo (+242). Mobile numbers are 9 national digits.
  static const congoBrazzaville = MsisdnPrefixTable('242', 9, {
    '06': MobileOperator.mtn,
    '05': MobileOperator.airtel,
    '04': MobileOperator.airtel,
  });

  MobileOperator lookup(String national) {
    for (var len = 3; len >= 2; len--) {
      if (national.length >= len) {
        final key = national.substring(0, len);
        final hit = prefixes[key];
        if (hit != null) return hit;
      }
    }
    return MobileOperator.unknown;
  }
}

final class InvalidPhoneNumber extends DomainFailure {
  const InvalidPhoneNumber(this.reason);
  final String reason;
  @override
  String get code => 'phone.invalid';
  @override
  Map<String, Object?> get params => {'reason': reason};
  @override
  String toString() => 'InvalidPhoneNumber($reason)';
}

/// A validated MSISDN, stored canonically as E.164 without the leading `+`.
final class PhoneNumber {
  const PhoneNumber._(this.e164, this.national, this.table);

  final String e164;
  final String national;
  final MsisdnPrefixTable table;

  MobileOperator get operator => table.lookup(national);

  static Result<PhoneNumber, InvalidPhoneNumber> parse(
    String input, {
    MsisdnPrefixTable table = MsisdnPrefixTable.congoBrazzaville,
  }) {
    var digits = input.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.startsWith('+')) digits = digits.substring(1);
    if (digits.startsWith('00')) digits = digits.substring(2);

    if (digits.isEmpty) return const Err(InvalidPhoneNumber('empty'));

    String national;
    if (digits.startsWith(table.countryCode) &&
        digits.length > table.countryCode.length) {
      national = digits.substring(table.countryCode.length);
    } else {
      national = digits;
    }

    // Congo-Brazzaville keeps the leading 0 in international form
    // (+242 06 123 45 67). Users still drop it, so accept both.
    if (national.length == table.nationalLength - 1 &&
        !national.startsWith('0')) {
      national = '0$national';
    }

    if (national.length != table.nationalLength) {
      return const Err(InvalidPhoneNumber('length'));
    }
    if (!national.startsWith('0')) {
      return const Err(InvalidPhoneNumber('format'));
    }

    return Ok(PhoneNumber._('${table.countryCode}$national', national, table));
  }

  /// `+242 06 123 45 67` — grouped the way Congolese numbers are read aloud
  /// (ADR-0008), leading 0 retained as local convention requires.
  String format() {
    const groups = [2, 3, 2, 2];
    final parts = <String>[];
    var i = 0;
    for (final g in groups) {
      if (i >= national.length) break;
      final end = (i + g) > national.length ? national.length : i + g;
      parts.add(national.substring(i, end));
      i = end;
    }
    if (i < national.length) parts.add(national.substring(i));
    return '+${table.countryCode} ${parts.join(' ')}';
  }

  @override
  bool operator ==(Object other) => other is PhoneNumber && other.e164 == e164;
  @override
  int get hashCode => e164.hashCode;
  @override
  String toString() => format();
}
