import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  PhoneNumber parseOk(String input) {
    final r = PhoneNumber.parse(input);
    expect(
      r.isOk,
      isTrue,
      reason: 'failed to parse "$input": ${r.failureOrNull}',
    );
    return r.valueOrNull!;
  }

  group('PhoneNumber — Congo-Brazzaville', () {
    test('accepts every way a user actually types their number', () {
      const forms = [
        '061234567',
        '06 123 45 67',
        '+242 06 123 45 67',
        '+242061234567',
        '00242061234567',
        '242061234567',
      ];
      final canonical = forms.map((f) => parseOk(f).e164).toSet();
      expect(
        canonical.length,
        1,
        reason: 'all forms must canonicalise identically: $canonical',
      );
    });

    test('formats the way Congolese numbers are read aloud', () {
      expect(parseOk('061234567').format(), '+242 06 123 45 67');
    });

    test('rejects a number that is too short', () {
      final r = PhoneNumber.parse('0612');
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, 'phone.invalid');
    });

    test('rejects empty input', () {
      expect(PhoneNumber.parse('').isErr, isTrue);
    });
  });

  group('operator detection drives the payment screen default', () {
    test('06 is MTN', () {
      expect(parseOk('061234567').operator, MobileOperator.mtn);
    });

    test('05 and 04 are Airtel', () {
      expect(parseOk('051234567').operator, MobileOperator.airtel);
      expect(parseOk('041234567').operator, MobileOperator.airtel);
    });

    test('an unknown prefix degrades rather than guessing', () {
      expect(parseOk('091234567').operator, MobileOperator.unknown);
    });

    test('the prefix table is data, so a renumbering is a config push', () {
      const table = MsisdnPrefixTable('242', 9, {'09': MobileOperator.orange});
      final r = PhoneNumber.parse('091234567', table: table);
      expect(r.valueOrNull!.operator, MobileOperator.orange);
    });
  });
}
