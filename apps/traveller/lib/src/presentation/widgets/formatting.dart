import 'package:bel_domain/bel_domain.dart';

/// Presentation formatting, in one place.
///
/// Not in `bel_design` — a component that knows about `Money` cannot be
/// rendered in a gallery — and not in the domain, which has no locale.
abstract final class Format {
  /// `06:00`. Twenty-four hour in both languages: Congo reads timetables that
  /// way, and an am/pm coach time is a coach missed.
  static String time(DateTime instant, {String timeZoneOffsetHours = '1'}) {
    final local = instant.add(
      Duration(hours: int.tryParse(timeZoneOffsetHours) ?? 1),
    );
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// `8 h` / `8 h 30`, or `8h` / `8h 30m` in English.
  static String duration(Duration d, {required String locale}) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final isFr = locale.startsWith('fr');

    if (minutes == 0) return isFr ? '$hours h' : '${hours}h';
    return isFr ? '$hours h $minutes' : '${hours}h ${minutes}m';
  }

  static String money(Money amount, {required String locale}) =>
      amount.format(locale: locale);

  /// `2026-08-15`, for the wire. Never shown to anyone.
  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// `sam. 15 août` / `Sat 15 Aug`. Written out rather than pulled from
  /// `intl`, which would add a megabyte of locale data to serve two languages.
  static String shortDate(DateTime d, {required String locale}) {
    final isFr = locale.startsWith('fr');
    final days = isFr
        ? ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.']
        : ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = isFr
        ? [
            'janv.',
            'févr.',
            'mars',
            'avr.',
            'mai',
            'juin',
            'juil.',
            'août',
            'sept.',
            'oct.',
            'nov.',
            'déc.',
          ]
        : [
            'Jan',
            'Feb',
            'Mar',
            'Apr',
            'May',
            'Jun',
            'Jul',
            'Aug',
            'Sep',
            'Oct',
            'Nov',
            'Dec',
          ];

    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}
