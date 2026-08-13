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

    test('a blocked seat is subtracted, not deleted', () {
      const draft = LayoutDraft(
        name: 'Car 60',
        sections: [
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 10,
            abreast: '2+2',
          ),
        ],
        blocked: {'3C', '7A'},
      );

      // Thirty-eight sellable seats in a coach that still has forty. The
      // manifest, the ticket and the conductor's count keep agreeing with the
      // physical coach; what changed is only what can be bought.
      expect(draft.capacity, 38);
      expect(draft.layout.allSeatLabels(), hasLength(40));
      expect(draft.layout.allSeatLabels(), contains('3C'));
    });

    test('blocked seats go on the wire in one order', () {
      const draft = LayoutDraft(
        name: 'Car 60',
        sections: [
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 10,
            abreast: '2+2',
          ),
        ],
        blocked: {'7A', '3C', '10D'},
      );

      // A Set has no order. Two operators blocking the same three seats in a
      // different order must produce the same bytes, or the audit trail
      // reports a change nobody made.
      expect(draft.toJson()['blocked'], ['10D', '3C', '7A']);
    });

    test('a door keeps its coordinates through the encoder', () {
      const draft = LayoutDraft(
        name: 'Car 62',
        sections: [
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 10,
            abreast: '2+2',
          ),
        ],
        features: [
          LayoutFeature(LayoutFeatureType.door, row: 5, col: 2),
          LayoutFeature(LayoutFeatureType.wc, row: 10, col: 4),
        ],
      );

      // Named by the enum, not by index: a reordered enum must not turn a
      // lavatory into a door on a coach that was drawn last year.
      expect(draft.toJson()['features'], [
        {'type': 'door', 'row': 5, 'col': 2},
        {'type': 'wc', 'row': 10, 'col': 4},
      ]);
      // A fitting is not a seat. Capacity is untouched by either of them.
      expect(draft.capacity, 40);
    });

    test('copyWith carries the blocks and the fittings', () {
      const draft = LayoutDraft(
        name: 'Car 63',
        sections: [
          CabinSection(
            code: 'STD',
            labelKey: 'seat.class.standard',
            rows: 10,
            abreast: '2+2',
          ),
        ],
        blocked: {'1A'},
        features: [LayoutFeature(LayoutFeatureType.door, row: 1, col: 0)],
      );

      // Renaming a draft used to be the way to lose everything the operator
      // had drawn on it, because copyWith only knew about the fields that
      // existed when it was written.
      final renamed = draft.copyWith(name: 'Car 64');
      expect(renamed.blocked, {'1A'});
      expect(renamed.features, hasLength(1));
      expect(renamed.capacity, 39);
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
