import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

DateTime day(int y, int m, int d) => DateTime.utc(y, m, d);

void main() {
  // 2026-08-03 is a Monday.
  final monday = day(2026, 8, 3);

  group('parsing the subset we honour', () {
    test('daily', () {
      final r = Recurrence.parse('FREQ=DAILY').valueOrNull!;
      expect(r.frequency, RecurrenceFrequency.daily);
      expect(r.interval, 1);
      expect(r.toRRule(), 'FREQ=DAILY');
    });

    test('weekly on named days', () {
      final r = Recurrence.parse('FREQ=WEEKLY;BYDAY=MO,WE,FR').valueOrNull!;
      expect(r.weekdays, {
        DateTime.monday,
        DateTime.wednesday,
        DateTime.friday,
      });
      expect(r.toRRule(), 'FREQ=WEEKLY;BYDAY=MO,WE,FR');
    });

    test('an interval', () {
      final r = Recurrence.parse('FREQ=DAILY;INTERVAL=2').valueOrNull!;
      expect(r.interval, 2);
      expect(r.toRRule(), 'FREQ=DAILY;INTERVAL=2');
    });

    test('the RRULE: prefix and lowercase are both accepted', () {
      expect(
        Recurrence.parse('rrule:freq=weekly;byday=sa,su').valueOrNull!.weekdays,
        {DateTime.saturday, DateTime.sunday},
      );
    });

    test('canonical form round-trips', () {
      for (final rule in [
        'FREQ=DAILY',
        'FREQ=DAILY;INTERVAL=3',
        'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR',
        'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU',
      ]) {
        expect(Recurrence.parse(rule).valueOrNull!.toRRule(), rule);
      }
    });
  });

  group('refusing what we cannot honour', () {
    // A partial implementation that ignored these would not fail — it would
    // materialise the WRONG departures, sell seats on them, and the operator
    // would find out when a coach did not arrive.
    test('an unsupported part is named, not ignored', () {
      final failure = Recurrence.parse(
        'FREQ=WEEKLY;BYDAY=MO;BYSETPOS=1',
      ).failureOrNull!;
      // "Unsupported RRULE" sends a dispatcher to support. Naming the part
      // does not.
      expect(failure.params['reason'], contains('BYSETPOS'));
    });

    test('monthly and yearly are refused', () {
      expect(Recurrence.parse('FREQ=MONTHLY').isErr, isTrue);
      expect(Recurrence.parse('FREQ=YEARLY').isErr, isTrue);
      expect(Recurrence.parse('FREQ=HOURLY').isErr, isTrue);
    });

    test('UNTIL and COUNT are refused rather than silently dropped', () {
      // The pattern row carries valid_from / valid_until, so a bound inside
      // the rule would be a second, silently disagreeing source of truth.
      expect(
        Recurrence.parse('FREQ=DAILY;UNTIL=20261231T000000Z').isErr,
        isTrue,
      );
      expect(Recurrence.parse('FREQ=DAILY;COUNT=10').isErr, isTrue);
    });

    test('FREQ=DAILY;BYDAY asks to be written unambiguously', () {
      // Legal RFC 5545, and it means something subtle. Rather than guess which
      // reading the dispatcher meant, ask for the form that cannot be read two
      // ways.
      final failure = Recurrence.parse('FREQ=DAILY;BYDAY=MO').failureOrNull!;
      expect(failure.params['reason'], contains('FREQ=WEEKLY'));
    });

    test('a missing or nonsense FREQ is refused', () {
      expect(Recurrence.parse('BYDAY=MO').isErr, isTrue);
      expect(Recurrence.parse('').isErr, isTrue);
      expect(Recurrence.parse('FREQ=WEEKLY').isErr, isTrue);
      expect(Recurrence.parse('FREQ=WEEKLY;BYDAY=XX').isErr, isTrue);
      expect(Recurrence.parse('FREQ=DAILY;INTERVAL=0').isErr, isTrue);
    });
  });

  group('expanding a timetable', () {
    test('every day', () {
      final dates = Recurrence.daily().datesBetween(
        monday,
        day(2026, 8, 9),
        anchor: monday,
      );
      expect(dates, hasLength(7));
    });

    test('Monday, Wednesday, Friday', () {
      final dates = Recurrence.weekly({
        DateTime.monday,
        DateTime.wednesday,
        DateTime.friday,
      }).datesBetween(monday, day(2026, 8, 9), anchor: monday);

      expect(dates.map((d) => d.day), [3, 5, 7]);
    });

    test('every other day, counted from the anchor', () {
      final dates = Recurrence.daily(
        interval: 2,
      ).datesBetween(monday, day(2026, 8, 9), anchor: monday);
      expect(dates.map((d) => d.day), [3, 5, 7, 9]);
    });

    test(
      'a fortnightly rule counts weeks from the anchor, as RFC 5545 does',
      () {
        // Anchored on Wednesday 5 August, running Mondays, every other week.
        //
        // The answer is 17 and 31 August, and the reasoning is worth writing
        // down because the intuitive answer is 10 August and it is wrong. Week
        // zero is the anchor's OWN week (3–9 August); its Monday is the 3rd,
        // which precedes the anchor and therefore does not run. Week one
        // (10–16) is skipped by the interval. Week two starts on the 17th.
        //
        // Counting from the anchor's week rather than from a fixed epoch is
        // what makes this stable: an epoch-based count gives a different answer
        // depending on which week of the year the schedule happened to start.
        final wednesday = day(2026, 8, 5);
        final dates = Recurrence.weekly(
          {DateTime.monday},
          interval: 2,
        ).datesBetween(wednesday, day(2026, 9, 1), anchor: wednesday);

        expect(dates.map((d) => '${d.month}-${d.day}'), ['8-17', '8-31']);
      },
    );

    test('nothing runs before the schedule starts', () {
      final dates = Recurrence.daily().datesBetween(
        day(2026, 7, 25),
        day(2026, 8, 5),
        anchor: monday,
      );
      expect(dates.first, monday);
    });

    test('both ends of the range are inclusive', () {
      final dates = Recurrence.daily().datesBetween(
        monday,
        monday,
        anchor: monday,
      );
      expect(dates, [monday]);
    });
  });
}
