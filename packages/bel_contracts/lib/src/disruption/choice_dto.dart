import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// One row on the passenger's choice screen (`08-disruption.md` §3.2).
final class TravelChoiceDto {
  const TravelChoiceDto({
    required this.id,
    required this.kind,
    required this.assigned,
    this.departureId,
    this.operatorName,
    this.departsAt,
    this.arrivesAt,
    this.seatsAvailable,
    this.seatLabels = const [],
    this.amount,
    this.otherOperator = false,
  });

  /// What the client sends back: a departure id, or `keep` / `refund`.
  final String id;

  /// `keep` · `move` · `refund`.
  final String kind;

  /// The one they already have. Exactly one row carries it, and it is what
  /// happens if they never answer.
  final bool assigned;

  final String? departureId;
  final String? operatorName;
  final DateTime? departsAt;

  /// On every travel row. The passenger is asking when they arrive, not when
  /// they leave, and a screen that answers the other question makes them do
  /// the arithmetic at a roadside.
  final DateTime? arrivesAt;

  final int? seatsAvailable;
  final List<String> seatLabels;

  /// On the refund row: what comes back.
  final Money? amount;

  final bool otherOperator;

  bool get isRefund => kind == 'refund';

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'kind': kind,
    'assigned': assigned,
    'departureId': departureId,
    'operatorName': operatorName,
    'departsAt': departsAt == null ? null : Wire.instant(departsAt!),
    'arrivesAt': arrivesAt == null ? null : Wire.instant(arrivesAt!),
    'seatsAvailable': seatsAvailable,
    'seatLabels': seatLabels,
    'amount': amount == null ? null : Wire.money(amount!),
    'otherOperator': otherOperator,
  });

  factory TravelChoiceDto.fromJson(Map<String, Object?> json) =>
      TravelChoiceDto(
        id: Wire.requireString(json['id'], 'id'),
        kind: Wire.requireString(json['kind'], 'kind'),
        assigned: json['assigned'] as bool? ?? false,
        departureId: json['departureId'] as String?,
        operatorName: json['operatorName'] as String?,
        departsAt: json['departsAt'] == null
            ? null
            : Wire.readInstant(json['departsAt'], field: 'departsAt'),
        arrivesAt: json['arrivesAt'] == null
            ? null
            : Wire.readInstant(json['arrivesAt'], field: 'arrivesAt'),
        seatsAvailable: json['seatsAvailable'] as int?,
        seatLabels: (json['seatLabels'] as List?)?.cast<String>() ?? const [],
        amount: json['amount'] == null
            ? null
            : Wire.readMoney(json['amount'], field: 'amount'),
        otherOperator: json['otherOperator'] as bool? ?? false,
      );

  /// How much of a party this row can take. Rendered as "18 sur 42" for the
  /// same reason the dispatcher's sheet does: the arithmetic belongs on the
  /// screen, not in the head of somebody standing on a roadside.
  int covered(int seatsNeeded) {
    final free = seatsAvailable;
    if (free == null) return seatsNeeded;
    return free < seatsNeeded ? free : seatsNeeded;
  }
}

/// The whole choice screen, in one response.
final class TravelChoicesDto {
  const TravelChoicesDto({
    required this.bookingRef,
    required this.options,
    required this.deadline,
    required this.seatsNeeded,
    required this.originCity,
    required this.destinationCity,
    required this.open,
    this.disruptionKind,
    this.reasonKey,
    this.note,
  });

  final String bookingRef;

  /// In display order: what they have, the alternatives, then the refund —
  /// always last and never hidden.
  final List<TravelChoiceDto> options;

  final DateTime deadline;
  final int seatsNeeded;
  final String originCity;
  final String destinationCity;

  /// False once the deadline has passed or the disruption was resolved. The
  /// screen still renders — a passenger who follows a link and finds nothing
  /// assumes the worst — but with no buttons.
  final bool open;

  final String? disruptionKind;

  /// The same sentence they were sent by SMS, so the screen and the message
  /// do not contradict each other.
  final String? reasonKey;

  final String? note;

  /// What happens to somebody who never answers. Stated on the screen,
  /// because ambiguity at 04:00 is worse than a rule somebody dislikes.
  TravelChoiceDto? get fallback => options.where((o) => o.assigned).firstOrNull;

  List<TravelChoiceDto> get alternatives => [
    for (final o in options)
      if (!o.assigned && !o.isRefund) o,
  ];

  TravelChoiceDto? get refund => options.where((o) => o.isRefund).firstOrNull;

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'options': [for (final o in options) o.toJson()],
    'deadline': Wire.instant(deadline),
    'seatsNeeded': seatsNeeded,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'open': open,
    'disruptionKind': disruptionKind,
    'reasonKey': reasonKey,
    'note': note,
  });

  factory TravelChoicesDto.fromJson(Map<String, Object?> json) =>
      TravelChoicesDto(
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        options: Wire.readList(
          json['options'],
          TravelChoiceDto.fromJson,
          field: 'options',
        ),
        deadline: Wire.readInstant(json['deadline'], field: 'deadline'),
        seatsNeeded: json['seatsNeeded'] as int? ?? 1,
        originCity: Wire.requireString(json['originCity'], 'originCity'),
        destinationCity: Wire.requireString(
          json['destinationCity'],
          'destinationCity',
        ),
        open: json['open'] as bool? ?? false,
        disruptionKind: json['disruptionKind'] as String?,
        reasonKey: json['reasonKey'] as String?,
        note: json['note'] as String?,
      );
}

/// Taking one.
final class TravelChoiceRequest {
  const TravelChoiceRequest({required this.optionId});

  final String optionId;

  Map<String, Object?> toJson() => {'optionId': optionId};

  factory TravelChoiceRequest.fromJson(Map<String, Object?> json) =>
      TravelChoiceRequest(
        optionId: Wire.requireString(json['optionId'], 'optionId'),
      );
}

/// What happened when they tapped.
final class ChoiceAppliedDto {
  const ChoiceAppliedDto({
    required this.bookingRef,
    required this.kind,
    this.departureId,
    this.departsAt,
    this.seatLabels = const [],
    this.refunded,
    this.claimCode,
  });

  final String bookingRef;
  final String kind;
  final String? departureId;
  final DateTime? departsAt;
  final List<String> seatLabels;

  /// On a refund: what comes back, and the code that collects it at a
  /// counter. Shown once here and sent by SMS as well, because a code that
  /// only ever existed on one screen is a code somebody loses.
  final Money? refunded;
  final String? claimCode;

  Map<String, Object?> toJson() => Wire.compact({
    'bookingRef': bookingRef,
    'kind': kind,
    'departureId': departureId,
    'departsAt': departsAt == null ? null : Wire.instant(departsAt!),
    'seatLabels': seatLabels,
    'refunded': refunded == null ? null : Wire.money(refunded!),
    'claimCode': claimCode,
  });

  factory ChoiceAppliedDto.fromJson(Map<String, Object?> json) =>
      ChoiceAppliedDto(
        bookingRef: Wire.requireString(json['bookingRef'], 'bookingRef'),
        kind: Wire.requireString(json['kind'], 'kind'),
        departureId: json['departureId'] as String?,
        departsAt: json['departsAt'] == null
            ? null
            : Wire.readInstant(json['departsAt'], field: 'departsAt'),
        seatLabels: (json['seatLabels'] as List?)?.cast<String>() ?? const [],
        refunded: json['refunded'] == null
            ? null
            : Wire.readMoney(json['refunded'], field: 'refunded'),
        claimCode: json['claimCode'] as String?,
      );
}
