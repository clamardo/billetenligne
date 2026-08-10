import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// The wire shape of a drawn layout.
///
/// Worth its own suite because three parties have to agree on it and only two
/// of them are in the same language at compile time: the console encodes, the
/// route parses, and neither would notice a dropped field until an operator
/// saw a coach come back with the wrong seats.
void main() {
  group('LayoutDraft', () {
    test('a section survives the round trip', () {
      const section = CabinSection(
        code: 'VIP',
        labelKey: 'seat.class.vip',
        rows: 3,
        abreast: '1+2',
        startRow: 4,
        numbering: SeatNumbering.sequential,
        modifier: PriceModifier.multiplier(1.5),
        pitchCm: 90,
      );

      final back = LayoutDraft.decodeSection(
        LayoutDraft.encodeSection(section),
      );

      expect(back.code, 'VIP');
      expect(back.labelKey, 'seat.class.vip');
      expect(back.rows, 3);
      expect(back.abreast, '1+2');
      expect(back.startRow, 4);
      expect(back.numbering, SeatNumbering.sequential);
      expect(back.pitchCm, 90);
      expect((back.modifier! as MultiplierModifier).value, 1.5);
    });

    test('a section is priced one way or not at all, never both', () {
      const multiplied = CabinSection(
        code: 'VIP',
        labelKey: 'seat.class.vip',
        rows: 1,
        abreast: '2+2',
        modifier: PriceModifier.multiplier(2),
      );
      const supplemented = CabinSection(
        code: 'VIP',
        labelKey: 'seat.class.vip',
        rows: 1,
        abreast: '2+2',
        modifier: PriceModifier.supplementMinor(1500),
      );
      const plain = CabinSection(
        code: 'STD',
        labelKey: 'seat.class.standard',
        rows: 1,
        abreast: '2+2',
      );

      // The server refuses a section that names both, so the encoder is what
      // guarantees a console can never send one — including by leaving a
      // stale null behind in the map.
      expect(
        LayoutDraft.encodeSection(multiplied).containsKey('fareSupplement'),
        isFalse,
      );
      expect(
        LayoutDraft.encodeSection(supplemented).containsKey('fareMultiplier'),
        isFalse,
      );
      expect(
        LayoutDraft.encodeSection(plain).containsKey('fareMultiplier'),
        isFalse,
      );
      expect(
        LayoutDraft.encodeSection(plain).containsKey('fareSupplement'),
        isFalse,
      );
    });

    test('capacity is the domain\'s, not a second count', () {
      const draft = LayoutDraft(
        name: 'Car 51',
        sections: [
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 11,
            abreast: '2+2',
          ),
          // The five-across rear bench every generic tool forgets.
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 1,
            abreast: '5',
            startRow: 12,
          ),
        ],
      );

      expect(draft.capacity, 49);
      expect(draft.isValid, isTrue);
      expect(draft.nextStartRow, 13);
    });

    test('an unnamed or unworkable draft knows it', () {
      const sections = [
        CabinSection(
          code: 'STD',
          labelKey: 'seat.class.standard',
          rows: 10,
          abreast: '2+2',
        ),
      ];

      expect(
        const LayoutDraft(name: '  ', sections: sections).isValid,
        isFalse,
      );
      expect(const LayoutDraft(name: 'x').isValid, isFalse);
      // `9+9` is eighteen seats across. The draft refuses it here so the save
      // button is disabled rather than enabled into a 400.
      expect(
        const LayoutDraft(
          name: 'x',
          sections: [
            CabinSection(
              code: 'STD',
              labelKey: 'seat.class.standard',
              rows: 10,
              abreast: '9+9',
            ),
          ],
        ).isValid,
        isFalse,
      );
    });

    test(
      'the request names the mode, so an aircraft is not filed as a coach',
      () {
        const draft = LayoutDraft(
          name: 'ATR 42',
          mode: TransportMode.air,
          sections: [
            CabinSection(
              code: 'Y',
              labelKey: 'seat.class.economy',
              rows: 10,
              abreast: '2+2',
            ),
          ],
        );

        final json = draft.toJson();
        expect(json['mode'], 'air');
        expect(json['name'], 'ATR 42');
        expect((json['sections']! as List), hasLength(1));
      },
    );
  });
}
