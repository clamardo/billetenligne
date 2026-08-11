import '../json/json_codec.dart';

/// One day of the funnel, on the wire.
///
/// The day travels as `YYYY-MM-DD`, **not** as an instant. It is a local
/// calendar day in the market's timezone, and an ISO timestamp would be
/// re-localised by whatever machine rendered it — a Monday in Brazzaville
/// arriving as a Sunday on a laptop set to Los Angeles.
///
/// Only counts cross the wire. The percentages are computed on both sides
/// from the same three numbers, so nobody can read a rate whose denominator
/// they cannot see.
final class FunnelDayDto {
  const FunnelDayDto({
    required this.day,
    required this.held,
    required this.reserved,
    required this.paid,
    required this.holdsLapsed,
    required this.paymentsFailed,
  });

  /// `YYYY-MM-DD`, local to the market.
  final String day;

  /// Seats claimed — the cohort. Every other figure on this row is about
  /// these holds, whenever the rest of the journey happened.
  final int held;

  /// Holds that became a booking.
  final int reserved;

  /// Bookings from those holds that were paid for.
  final int paid;

  /// Holds that timed out or were given up.
  final int holdsLapsed;

  /// Bookings whose payment the rail refused at least once. Counted per
  /// booking, not per attempt: three retries by one traveller is one person
  /// having a bad evening, not three.
  final int paymentsFailed;

  int? get holdToReservation => _rate(reserved, held);
  int? get reservationToPaid => _rate(paid, reserved);
  int? get holdToPaid => _rate(paid, held);

  /// Null, not zero, when nothing happened: nought out of nought is a quiet
  /// day, and a screen that draws it as 0% invents an outage every Sunday.
  static int? _rate(int part, int whole) =>
      whole == 0 ? null : (100 * part / whole).round();

  Map<String, Object?> toJson() => {
    'day': day,
    'held': held,
    'reserved': reserved,
    'paid': paid,
    'holdsLapsed': holdsLapsed,
    'paymentsFailed': paymentsFailed,
  };

  factory FunnelDayDto.fromJson(Map<String, Object?> json) => FunnelDayDto(
    day: Wire.requireString(json['day'], 'day'),
    held: json['held'] as int? ?? 0,
    reserved: json['reserved'] as int? ?? 0,
    paid: json['paid'] as int? ?? 0,
    holdsLapsed: json['holdsLapsed'] as int? ?? 0,
    paymentsFailed: json['paymentsFailed'] as int? ?? 0,
  );
}

/// The funnel, and what it is honest about.
///
/// [countsFrom] names the first step that leaves a row anywhere. There is no
/// search-to-hold figure and there will not be one until somebody builds a
/// telemetry path with its own consent question — so the response says where
/// the measurement starts rather than letting a reader take "conversion" for
/// search-to-ticket.
final class FunnelDto {
  const FunnelDto({
    required this.days,
    this.channel = 'app',
    this.countsFrom = 'hold',
    this.operatorId,
  });

  /// Newest first: the question is nearly always about this week.
  final List<FunnelDayDto> days;

  final String channel;
  final String countsFrom;

  /// Set when somebody narrowed the view to one company.
  final String? operatorId;

  /// The largest day-over-day fall in hold→payment conversion, in points,
  /// or null when fewer than two days carry a figure.
  ///
  /// `04-payments.md` §8 raises an alert past ten points. Computed here, from
  /// the same list the screen draws, so the number in the alert and the
  /// number on the screen cannot disagree.
  int? get worstDrop {
    int? worst;
    for (var i = 0; i < days.length - 1; i++) {
      // Newest first, so [i] is the later day and [i + 1] the one before it.
      final today = days[i].holdToPaid;
      final before = days[i + 1].holdToPaid;
      if (today == null || before == null) continue;
      final drop = before - today;
      if (drop > 0 && (worst == null || drop > worst)) worst = drop;
    }
    return worst;
  }

  Map<String, Object?> toJson() => Wire.compact({
    'days': [for (final d in days) d.toJson()],
    'channel': channel,
    'countsFrom': countsFrom,
    'operatorId': operatorId,
  });

  factory FunnelDto.fromJson(Map<String, Object?> json) => FunnelDto(
    days: Wire.readList(json['days'], FunnelDayDto.fromJson, field: 'days'),
    channel: json['channel'] as String? ?? 'app',
    countsFrom: json['countsFrom'] as String? ?? 'hold',
    operatorId: json['operatorId'] as String?,
  );
}
