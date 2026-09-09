import 'package:bel_platform/bel_platform.dart';
import 'package:test/test.dart';

void main() {
  final noon = DateTime.utc(2026, 9, 9, 12);

  ClockOffset measured(Duration behind, {DateTime? at}) => ClockOffset.between(
    serverTime: (at ?? noon).add(behind),
    deviceTime: at ?? noon,
  );

  group('measuring', () {
    test('a slow handset yields a positive offset', () {
      final offset = measured(const Duration(minutes: 20));
      expect(offset.offset, const Duration(minutes: 20));
      expect(offset.correct(noon), noon.add(const Duration(minutes: 20)));
    });

    test('a fast handset yields a negative one', () {
      final offset = measured(const Duration(minutes: -7));
      expect(offset.correct(noon), noon.subtract(const Duration(minutes: 7)));
    });

    test('the capture is recorded in device time, not server time', () {
      // The only scale on which "has this clock jumped since?" can be asked.
      final offset = measured(const Duration(hours: 3));
      expect(offset.capturedAtDevice, noon);
    });
  });

  group('applying it', () {
    test('the correction still holds a week later', () {
      // A handset that is twenty minutes slow is twenty minutes slow at the
      // coach door too. This is the whole case: the measurement was taken at
      // purchase, when they had signal, and the door has none.
      final offset = measured(const Duration(minutes: 20));
      final door = noon.add(const Duration(days: 7));
      expect(offset.correct(door), door.add(const Duration(minutes: 20)));
    });

    test('a few seconds is left alone', () {
      // Inside the noise between the `Date` header being written and read, and
      // far inside the ±90 s the scanner already tolerates.
      final offset = measured(const Duration(seconds: 3));
      expect(offset.correct(noon), noon);
    });
  });

  group('when the clock has moved under us', () {
    test('a clock that went backwards is not trusted', () {
      // Corrected downwards, or set by hand. Either way the difference we
      // recorded is not the difference that exists now.
      final offset = measured(const Duration(minutes: 20));
      final earlier = noon.subtract(const Duration(minutes: 1));
      expect(offset.trustedAt(earlier), isFalse);
      expect(offset.correct(earlier), earlier, reason: 'raw device time');
    });

    test('a measurement older than the sales horizon is not trusted', () {
      final offset = measured(const Duration(minutes: 20));
      final muchLater = noon.add(const Duration(days: 31));
      expect(offset.trustedAt(muchLater), isFalse);
      expect(offset.correct(muchLater), muchLater);
    });

    test('exactly at the age limit it is still applied', () {
      final offset = measured(const Duration(minutes: 20));
      final atLimit = noon.add(ClockOffset.maxAge);
      expect(offset.trustedAt(atLimit), isTrue);
    });

    // The property that makes this safe to adopt everywhere at once: a
    // distrusted offset leaves the caller exactly where it was before this
    // type existed. Nothing here can refuse somebody who would have boarded.
    test('distrust degrades to the behaviour that existed before', () {
      final offset = measured(const Duration(hours: 5));
      final backwards = noon.subtract(const Duration(seconds: 1));
      expect(offset.correct(backwards), backwards);
    });
  });

  group('carrying it across a cold start', () {
    test('round trips through JSON', () {
      final offset = measured(const Duration(minutes: 20, seconds: 30));
      final back = ClockOffset.fromJson(offset.toJson())!;
      expect(back.offset, offset.offset);
      expect(back.capturedAtDevice, offset.capturedAtDevice);
    });

    test('junk reads as nothing rather than as a wrong offset', () {
      // A vault row written by an older build, or a truncated write. Answering
      // null falls back to the device clock; answering a guess would move
      // everybody's code by a made-up amount.
      expect(ClockOffset.fromJson(null), isNull);
      expect(ClockOffset.fromJson(const {}), isNull);
      expect(ClockOffset.fromJson(const {'offsetMs': 'soon'}), isNull);
      expect(
        ClockOffset.fromJson(const {
          'offsetMs': 60000,
          'capturedAtDevice': 'not a date',
        }),
        isNull,
      );
    });
  });

  group('CorrectedClock', () {
    test('answers with the corrected time', () {
      final clock = CorrectedClock(
        device: FixedClock(noon),
        offset: () => measured(const Duration(minutes: 20)),
      );
      expect(clock.now(), noon.add(const Duration(minutes: 20)));
    });

    test('answers with the device clock when there is no measurement', () {
      final clock = CorrectedClock(
        device: FixedClock(noon),
        offset: () => null,
      );
      expect(clock.now(), noon);
    });

    test('reads the offset per call, so a refresh is seen immediately', () {
      // The client updates it on every response, including refusals. A screen
      // holding a copy taken at build time would keep showing the stale one.
      ClockOffset? current;
      final clock = CorrectedClock(
        device: FixedClock(noon),
        offset: () => current,
      );
      expect(clock.now(), noon);
      current = measured(const Duration(minutes: 20));
      expect(clock.now(), noon.add(const Duration(minutes: 20)));
    });
  });
}
