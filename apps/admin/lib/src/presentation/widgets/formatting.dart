/// Presentation formatting, in one place.
///
/// A back-office copy rather than a shared one: the traveller app's `Format`
/// speaks in coach times and fares, and this one speaks in filing dates and
/// how long somebody has been waiting. Sharing them would mean one class that
/// serves neither well.
abstract final class Format {
  /// `15/08/2026`. The order every form in Congo uses.
  static String date(DateTime d) {
    final local = d.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  /// `15/08/2026 14:32`.
  static String dateTime(DateTime d) {
    final local = d.toLocal();
    return '${date(d)} ${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// How long something has been waiting, in the coarsest honest unit.
  ///
  /// `3 j` / `4 h` / `12 min`. Coarse on purpose: a reviewer decides on the
  /// order of a queue, and a queue sorted by seconds is a queue that looks
  /// different every time it refreshes.
  static String age(Duration d, {required String locale}) {
    final isFr = locale.startsWith('fr');
    if (d.inDays >= 1) return isFr ? '${d.inDays} j' : '${d.inDays}d';
    if (d.inHours >= 1) return isFr ? '${d.inHours} h' : '${d.inHours}h';
    final minutes = d.inMinutes < 1 ? 1 : d.inMinutes;
    return isFr ? '$minutes min' : '${minutes}m';
  }

  /// `+242 06 123 45 67` where we can, and the raw digits where we cannot.
  static String msisdn(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9+]'), '');
    if (!digits.startsWith('+242') || digits.length != 13) return value;
    return '+242 ${digits.substring(4, 6)} ${digits.substring(6, 9)} '
        '${digits.substring(9, 11)} ${digits.substring(11)}';
  }
}
