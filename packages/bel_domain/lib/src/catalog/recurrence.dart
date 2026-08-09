import '../shared/failure.dart';
import '../shared/result.dart';

final class InvalidRecurrence extends DomainFailure {
  const InvalidRecurrence(this.reason);
  final String reason;
  @override
  String get code => 'schedule.invalid_rrule';
  @override
  Map<String, Object?> get params => {'reason': reason};
  @override
  String toString() => 'InvalidRecurrence($reason)';
}

/// When a scheduled service runs.
///
/// A **deliberate subset of RFC 5545** — `FREQ=DAILY` and
/// `FREQ=WEEKLY;BYDAY=…`, with an optional `INTERVAL` — and it **refuses
/// everything else** rather than ignoring the parts it does not understand.
///
/// That refusal is the whole design decision. A partial RRULE implementation
/// that silently drops `BYSETPOS` or `UNTIL` does not fail: it materialises
/// the wrong departures, sells seats on them, and the operator finds out when
/// a coach does not arrive. Refusing an expression we cannot honour is a
/// dispatcher seeing an error on a configuration screen, which is the cheapest
/// possible place to find out.
///
/// The subset is not a compromise either. Intercity coach timetables in Congo
/// are "every day at 06:00" and "Monday, Wednesday, Friday at 14:00". The full
/// standard exists for calendars, and this is not a calendar.
final class Recurrence {
  const Recurrence._({
    required this.frequency,
    required this.interval,
    required this.weekdays,
  });

  final RecurrenceFrequency frequency;

  /// Every *n*th day or week. 1 unless `INTERVAL=` says otherwise.
  final int interval;

  /// ISO weekday numbers, Monday = 1. Empty for a daily rule.
  final Set<int> weekdays;

  static const _byDay = {
    'MO': DateTime.monday,
    'TU': DateTime.tuesday,
    'WE': DateTime.wednesday,
    'TH': DateTime.thursday,
    'FR': DateTime.friday,
    'SA': DateTime.saturday,
    'SU': DateTime.sunday,
  };

  /// The two rules that cover every real timetable, so a dispatcher rarely has
  /// to see the letters RRULE at all.
  static Recurrence daily({int interval = 1}) => Recurrence._(
    frequency: RecurrenceFrequency.daily,
    interval: interval,
    weekdays: const {},
  );

  static Recurrence weekly(Set<int> weekdays, {int interval = 1}) =>
      Recurrence._(
        frequency: RecurrenceFrequency.weekly,
        interval: interval,
        weekdays: weekdays,
      );

  static Result<Recurrence, InvalidRecurrence> parse(String rrule) {
    final parts = <String, String>{};
    for (final segment in rrule.toUpperCase().replaceAll('RRULE:', '').split(';')) {
      if (segment.trim().isEmpty) continue;
      final eq = segment.indexOf('=');
      if (eq <= 0) return Err(InvalidRecurrence('malformed part "$segment"'));
      parts[segment.substring(0, eq).trim()] = segment.substring(eq + 1).trim();
    }

    // Named one at a time rather than checked as a set difference, so the
    // error says which part we cannot honour. "Unsupported RRULE" sends a
    // dispatcher to support; "we do not support BYSETPOS" does not.
    const supported = {'FREQ', 'INTERVAL', 'BYDAY'};
    for (final key in parts.keys) {
      if (!supported.contains(key)) {
        return Err(InvalidRecurrence('unsupported part $key'));
      }
    }

    final freq = parts['FREQ'];
    if (freq == null) return const Err(InvalidRecurrence('missing FREQ'));

    final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 0;
    if (interval < 1) return const Err(InvalidRecurrence('INTERVAL must be >= 1'));

    switch (freq) {
      case 'DAILY':
        if (parts.containsKey('BYDAY')) {
          // FREQ=DAILY;BYDAY=MO is legal RFC 5545 and means something subtle.
          // Expressing it as FREQ=WEEKLY is unambiguous, so we ask for that
          // rather than guessing which reading the dispatcher meant.
          return const Err(
            InvalidRecurrence('use FREQ=WEEKLY;BYDAY for specific days'),
          );
        }
        return Ok(Recurrence.daily(interval: interval));

      case 'WEEKLY':
        final byDay = parts['BYDAY'];
        if (byDay == null || byDay.isEmpty) {
          return const Err(InvalidRecurrence('WEEKLY needs BYDAY'));
        }
        final days = <int>{};
        for (final token in byDay.split(',')) {
          final day = _byDay[token.trim()];
          if (day == null) {
            return Err(InvalidRecurrence('unknown day "$token"'));
          }
          days.add(day);
        }
        return Ok(Recurrence.weekly(days, interval: interval));

      default:
        return Err(InvalidRecurrence('unsupported FREQ=$freq'));
    }
  }

  /// Canonical form, for storage. Round-trips through [parse].
  String toRRule() => switch (frequency) {
    RecurrenceFrequency.daily =>
      interval == 1 ? 'FREQ=DAILY' : 'FREQ=DAILY;INTERVAL=$interval',
    RecurrenceFrequency.weekly => [
      'FREQ=WEEKLY',
      if (interval != 1) 'INTERVAL=$interval',
      'BYDAY=${(weekdays.toList()..sort()).map(_dayCode).join(',')}',
    ].join(';'),
  };

  static String _dayCode(int weekday) =>
      _byDay.entries.firstWhere((e) => e.value == weekday).key;

  /// Whether a service runs on [date], counting intervals from [anchor].
  ///
  /// Both are **local calendar dates**, never instants. "Does the Monday coach
  /// run on the 15th?" is a local question, and comparing UTC timestamps puts
  /// the 06:00 departure on the wrong day for half the year in a country that
  /// is an hour off UTC.
  bool runsOn(DateTime date, {required DateTime anchor}) {
    final day = DateTime.utc(date.year, date.month, date.day);
    final from = DateTime.utc(anchor.year, anchor.month, anchor.day);
    if (day.isBefore(from)) return false;

    return switch (frequency) {
      RecurrenceFrequency.daily =>
        day.difference(from).inDays % interval == 0,
      RecurrenceFrequency.weekly =>
        weekdays.contains(day.weekday) &&
            // Weeks counted from the anchor's own week, so INTERVAL=2 on a
            // rule anchored mid-week does not skip the first Monday.
            (_weekIndex(day) - _weekIndex(from)) % interval == 0,
    };
  }

  /// Every date in `[from, to]` this rule runs on, inclusive at both ends.
  List<DateTime> datesBetween(
    DateTime from,
    DateTime to, {
    required DateTime anchor,
  }) {
    final dates = <DateTime>[];
    var day = DateTime.utc(from.year, from.month, from.day);
    final last = DateTime.utc(to.year, to.month, to.day);

    while (!day.isAfter(last)) {
      if (runsOn(day, anchor: anchor)) dates.add(day);
      day = day.add(const Duration(days: 1));
    }
    return dates;
  }

  /// Monday-based week number since the epoch, used only for INTERVAL maths.
  static int _weekIndex(DateTime day) =>
      (day.difference(DateTime.utc(1970, 1, 5)).inDays / 7).floor();

  @override
  String toString() => toRRule();
}

enum RecurrenceFrequency { daily, weekly }
