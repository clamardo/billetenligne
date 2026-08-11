import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// One later coach a missed passenger could be put on, priced.
///
/// The station is the point of the row. A passenger who missed the 06:00 from
/// Mikalou can often be put on the 09:30 from Kinsoundi — and an agent who
/// cannot see that is an agent who sends somebody to the wrong side of a city
/// with a suitcase.
final class MissedOptionDto {
  const MissedOptionDto({
    required this.departureId,
    required this.departsAt,
    required this.arrivesAt,
    required this.fare,
    required this.seatsAvailable,
    this.stationName,
    this.boardingNotes,
    this.sameStation = true,
    this.fee,
    this.fareDifference,
    this.owed,
    this.refusalCode,
  });

  final String departureId;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final Money fare;
  final int seatsAvailable;

  final String? stationName;
  final String? boardingNotes;

  /// False when this coach leaves from somewhere other than the yard they
  /// were told to come to. Decided on the server, so the agent's screen and
  /// the passenger's re-issued ticket cannot disagree about which yard.
  final bool sameStation;

  /// Null together with [owed] when [refusalCode] is set.
  final Money? fee;
  final Money? fareDifference;
  final Money? owed;

  /// Why this row cannot be taken. Shown rather than dropped: a coach missing
  /// from a list is a coach the agent telephones the depot about.
  final String? refusalCode;

  bool get isTakeable => refusalCode == null;
  bool get isFree => owed != null && owed!.minor == 0;

  Map<String, Object?> toJson() => Wire.compact({
    'departureId': departureId,
    'departsAt': Wire.instant(departsAt),
    'arrivesAt': Wire.instant(arrivesAt),
    'fare': Wire.money(fare),
    'seatsAvailable': seatsAvailable,
    'stationName': stationName,
    'boardingNotes': boardingNotes,
    // Only when it is false. The common case is one yard, and a flag that is
    // always present on every row is bytes on a 2G connection.
    'sameStation': sameStation ? null : false,
    'fee': fee == null ? null : Wire.money(fee!),
    'fareDifference': fareDifference == null
        ? null
        : Wire.money(fareDifference!),
    'owed': owed == null ? null : Wire.money(owed!),
    'refusalCode': refusalCode,
  });

  factory MissedOptionDto.fromJson(Map<String, Object?> json) =>
      MissedOptionDto(
        departureId: Wire.requireString(json['departureId'], 'departureId'),
        departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
        arrivesAt: Wire.readInstant(json['arrivesAt'], field: 'arrivesAt'),
        fare: Wire.readMoney(json['fare'], field: 'fare'),
        seatsAvailable: Wire.requireInt(
          json['seatsAvailable'],
          'seatsAvailable',
        ),
        stationName: json['stationName'] as String?,
        boardingNotes: json['boardingNotes'] as String?,
        sameStation: json['sameStation'] as bool? ?? true,
        fee: json['fee'] == null ? null : Wire.readMoney(json['fee']),
        fareDifference: json['fareDifference'] == null
            ? null
            : Wire.readMoney(json['fareDifference']),
        owed: json['owed'] == null ? null : Wire.readMoney(json['owed']),
        refusalCode: json['refusalCode'] as String?,
      );
}

/// The counter's whole screen for a passenger who was late.
final class MissedOptionsDto {
  const MissedOptionsDto({
    required this.bookingRef,
    required this.originCity,
    required this.destinationCity,
    required this.seatsNeeded,
    required this.departedAt,
    required this.paidFare,
    required this.options,
    this.terms = const [],
    this.fromStationName,
    this.involuntary = false,
    this.refusalCode,
  });

  final String bookingRef;
  final String originCity;
  final String destinationCity;
  final int seatsNeeded;

  /// When the coach they hold a ticket for actually left.
  final DateTime departedAt;

  final Money paidFare;
  final List<MissedOptionDto> options;

  /// The operator's terms as catalog keys, written by the domain and rendered
  /// by whichever surface reads them (ADR-0008). The agent reads these aloud;
  /// they are the company's promise, not ours.
  final List<String> terms;

  final String? fromStationName;

  /// The operator caused this. Free inside every window there is (ADR-0016).
  final bool involuntary;

  /// Set when nothing can be done at all — not offered, window closed, or the
  /// coach has not left yet.
  final String? refusalCode;

  bool get isPossible => refusalCode == null;

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'seatsNeeded': seatsNeeded,
    'departedAt': Wire.instant(departedAt),
    'paidFare': Wire.money(paidFare),
    'options': [for (final o in options) o.toJson()],
    'terms': terms.isEmpty ? null : terms,
    'fromStationName': fromStationName,
    'involuntary': involuntary ? true : null,
    'refusalCode': refusalCode,
  });

  factory MissedOptionsDto.fromJson(Map<String, Object?> json) =>
      MissedOptionsDto(
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        originCity: Wire.requireString(json['originCity'], 'originCity'),
        destinationCity: Wire.requireString(
          json['destinationCity'],
          'destinationCity',
        ),
        seatsNeeded: json['seatsNeeded'] as int? ?? 1,
        departedAt: Wire.readInstant(json['departedAt'], field: 'departedAt'),
        paidFare: Wire.readMoney(json['paidFare'], field: 'paidFare'),
        options: Wire.readList(
          json['options'],
          MissedOptionDto.fromJson,
          field: 'options',
        ),
        terms: [for (final t in (json['terms'] as List? ?? const [])) '$t'],
        fromStationName: json['fromStationName'] as String?,
        involuntary: json['involuntary'] as bool? ?? false,
        refusalCode: json['refusalCode'] as String?,
      );
}

/// What the counter did.
final class MissedTransferDto {
  const MissedTransferDto({
    required this.bookingRef,
    required this.departureId,
    required this.departsAt,
    required this.seatLabels,
    required this.paid,
    this.stationName,
    this.boardingNotes,
  });

  final String bookingRef;
  final String departureId;
  final DateTime departsAt;
  final List<String> seatLabels;

  /// What was taken across the counter, so the receipt and the drawer agree.
  final Money paid;

  /// Where the new coach leaves from — the sentence the agent says out loud
  /// and the passenger walks away repeating.
  final String? stationName;
  final String? boardingNotes;

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'departureId': departureId,
    'departsAt': Wire.instant(departsAt),
    'seatLabels': seatLabels,
    'paid': Wire.money(paid),
    'stationName': stationName,
    'boardingNotes': boardingNotes,
  });

  factory MissedTransferDto.fromJson(Map<String, Object?> json) =>
      MissedTransferDto(
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        departureId: Wire.requireString(json['departureId'], 'departureId'),
        departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
        seatLabels: [
          for (final s in (json['seatLabels'] as List? ?? const [])) '$s',
        ],
        paid: Wire.readMoney(json['paid'], field: 'paid'),
        stationName: json['stationName'] as String?,
        boardingNotes: json['boardingNotes'] as String?,
      );
}
