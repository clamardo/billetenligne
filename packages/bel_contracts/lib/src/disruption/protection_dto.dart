import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// A standing agreement, as one of its two parties sees it
/// (`08-disruption.md` §5).
///
/// The counterparty is named rather than identified: the operator reading
/// this knows the other company as "Trans Bony Voyages", and which side of
/// `operatorA`/`operatorB` they happen to sit on is our bookkeeping.
final class ProtectionAgreementDto {
  const ProtectionAgreementDto({
    required this.id,
    required this.counterpartyId,
    required this.counterpartyName,
    required this.state,
    required this.corridors,
    required this.reciprocal,
    required this.rebillDiscountBps,
    required this.weProposed,
    required this.proposedAt,
    required this.seatsUsedThisMonth,
    this.monthlyCapSeats,
    this.autoAcceptWhenSpareAbove,
    this.acceptedAt,
    this.endedAt,
    this.endedReason,
  });

  final String id;
  final String counterpartyId;
  final String counterpartyName;

  /// `proposed` · `active` · `suspended` · `ended`.
  final String state;

  /// Normalised `BZV~PNR` keys, so the two directions are one value.
  final List<String> corridors;

  final bool reciprocal;

  /// `1500` is "tarif public − 15%".
  final int rebillDiscountBps;

  /// Whether the operator reading this wrote the terms. Decides whether the
  /// screen says "waiting for them" or "they are waiting for you".
  final bool weProposed;

  final DateTime proposedAt;

  /// So a ceiling reads `31 / 40` on the screen rather than on refusal.
  final int seatsUsedThisMonth;

  final int? monthlyCapSeats;
  final int? autoAcceptWhenSpareAbove;
  final DateTime? acceptedAt;
  final DateTime? endedAt;
  final String? endedReason;

  bool get isActive => state == 'active';

  /// In force **and** with room left under this month's ceiling.
  ///
  /// The question the disruption sheet asks before it draws option ③. An
  /// agreement that is active and exhausted refuses every request until the
  /// first of the month, and offering it at 05:40 is worse than not offering
  /// it at all.
  bool get isLive =>
      isActive &&
      (monthlyCapSeats == null || seatsUsedThisMonth < monthlyCapSeats!);

  /// This side has been asked to agree to somebody else's terms.
  bool get awaitingUs => !weProposed && state == 'proposed';

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'counterpartyId': counterpartyId,
    'counterpartyName': counterpartyName,
    'state': state,
    'corridors': corridors,
    'reciprocal': reciprocal,
    'rebillDiscountBps': rebillDiscountBps,
    'weProposed': weProposed,
    'proposedAt': Wire.instant(proposedAt),
    'seatsUsedThisMonth': seatsUsedThisMonth,
    'monthlyCapSeats': monthlyCapSeats,
    'autoAcceptWhenSpareAbove': autoAcceptWhenSpareAbove,
    'acceptedAt': acceptedAt == null ? null : Wire.instant(acceptedAt!),
    'endedAt': endedAt == null ? null : Wire.instant(endedAt!),
    'endedReason': endedReason,
  });

  factory ProtectionAgreementDto.fromJson(Map<String, Object?> json) =>
      ProtectionAgreementDto(
        id: Wire.requireString(json['id'], 'id'),
        counterpartyId: Wire.requireString(
          json['counterpartyId'],
          'counterpartyId',
        ),
        counterpartyName: Wire.requireString(
          json['counterpartyName'],
          'counterpartyName',
        ),
        state: Wire.requireString(json['state'], 'state'),
        corridors: (json['corridors'] as List?)?.cast<String>() ?? const [],
        reciprocal: json['reciprocal'] as bool? ?? true,
        rebillDiscountBps: Wire.requireInt(
          json['rebillDiscountBps'],
          'rebillDiscountBps',
        ),
        weProposed: json['weProposed'] as bool? ?? false,
        proposedAt: Wire.readInstant(json['proposedAt'], field: 'proposedAt'),
        seatsUsedThisMonth: json['seatsUsedThisMonth'] as int? ?? 0,
        monthlyCapSeats: json['monthlyCapSeats'] as int?,
        autoAcceptWhenSpareAbove: json['autoAcceptWhenSpareAbove'] as int?,
        acceptedAt: json['acceptedAt'] == null
            ? null
            : Wire.readInstant(json['acceptedAt'], field: 'acceptedAt'),
        endedAt: json['endedAt'] == null
            ? null
            : Wire.readInstant(json['endedAt'], field: 'endedAt'),
        endedReason: json['endedReason'] as String?,
      );

  /// The corridors as domain values, for a screen that wants to render them
  /// or ask whether one covers a journey.
  List<Corridor> get parsedCorridors => [
    for (final key in corridors) Corridor.parse(key),
  ];

  /// Whether this agreement covers a road, in either direction.
  ///
  /// A corridor is unordered — BZV↔PNR is one road, not two — and the domain
  /// type is what says so, here as on the server (ADR-0004).
  bool covers(String origin, String destination) =>
      parsedCorridors.any((c) => c.covers(origin, destination));
}

/// Writing the terms.
final class ProposeAgreementRequest {
  const ProposeAgreementRequest({
    required this.counterpartyCode,
    required this.corridors,
    this.reciprocal = true,
    this.rebillDiscountBps = 0,
    this.monthlyCapSeats,
    this.autoAcceptWhenSpareAbove,
  });

  /// The other company's operator code — `TBV`. What one operator calls
  /// another; the id appears on no document either of them holds.
  final String counterpartyCode;

  /// Normalised `BZV~PNR` keys.
  final List<String> corridors;

  final bool reciprocal;
  final int rebillDiscountBps;
  final int? monthlyCapSeats;
  final int? autoAcceptWhenSpareAbove;

  Map<String, Object?> toJson() => Wire.compact({
    'counterpartyCode': counterpartyCode,
    'corridors': corridors,
    'reciprocal': reciprocal,
    'rebillDiscountBps': rebillDiscountBps,
    'monthlyCapSeats': monthlyCapSeats,
    'autoAcceptWhenSpareAbove': autoAcceptWhenSpareAbove,
  });

  factory ProposeAgreementRequest.fromJson(Map<String, Object?> json) =>
      ProposeAgreementRequest(
        counterpartyCode: Wire.requireString(
          json['counterpartyCode'],
          'counterpartyCode',
        ),
        corridors: (json['corridors'] as List?)?.cast<String>() ?? const [],
        reciprocal: json['reciprocal'] as bool? ?? true,
        rebillDiscountBps: json['rebillDiscountBps'] as int? ?? 0,
        monthlyCapSeats: json['monthlyCapSeats'] as int?,
        autoAcceptWhenSpareAbove: json['autoAcceptWhenSpareAbove'] as int?,
      );
}

/// `accept` · `decline` · `suspend` · `resume` · `end`.
final class AgreementDecisionRequest {
  const AgreementDecisionRequest({required this.decision, this.reason});

  final String decision;
  final String? reason;

  Map<String, Object?> toJson() =>
      Wire.compact({'decision': decision, 'reason': reason});

  factory AgreementDecisionRequest.fromJson(Map<String, Object?> json) =>
      AgreementDecisionRequest(
        decision: Wire.requireString(json['decision'], 'decision'),
        reason: json['reason'] as String?,
      );
}

/// One company asking another for room, on the wire (`08-disruption.md` §2.3).
final class ProtectionRequestDto {
  const ProtectionRequestDto({
    required this.id,
    required this.agreementId,
    required this.counterpartyName,
    required this.weAsked,
    required this.fromDepartureId,
    required this.toDepartureId,
    required this.seatsRequested,
    required this.state,
    required this.requestedAt,
    this.note,
    this.routeCode,
    this.departsAt,
    this.replacementDepartsAt,
    this.seatsFree = 0,
    this.rebill,
    this.autoAccepted = false,
    this.seatsMoved,
    this.declineReason,
  });

  final String id;
  final String agreementId;
  final String counterpartyName;

  /// Whether this is ours to chase or ours to answer.
  final bool weAsked;

  final String fromDepartureId;
  final String toDepartureId;
  final int seatsRequested;

  /// `pending` · `accepted` · `declined` · `applied` · `expired` · `failed`.
  final String state;

  final DateTime requestedAt;
  final String? note;

  /// Enough of the journey to decide without opening anything else. A
  /// receiving operator deciding blind is one who says no.
  final String? routeCode;
  final DateTime? departsAt;
  final DateTime? replacementDepartsAt;
  final int seatsFree;

  /// What the receiving operator would be paid at the agreed discount, for
  /// the seats being asked for. Before the decision, not after.
  final Money? rebill;

  final bool autoAccepted;
  final int? seatsMoved;
  final String? declineReason;

  bool get isPending => state == 'pending';
  bool get awaitingUs => isPending && !weAsked;

  /// Everybody asked for got a seat. Partial coverage is a success and is
  /// said as a number, so this is a different question from "did it work".
  bool get coversEverybody =>
      seatsMoved != null && seatsMoved! >= seatsRequested;

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'agreementId': agreementId,
    'counterpartyName': counterpartyName,
    'weAsked': weAsked,
    'fromDepartureId': fromDepartureId,
    'toDepartureId': toDepartureId,
    'seatsRequested': seatsRequested,
    'state': state,
    'requestedAt': Wire.instant(requestedAt),
    'note': note,
    'routeCode': routeCode,
    'departsAt': departsAt == null ? null : Wire.instant(departsAt!),
    'replacementDepartsAt': replacementDepartsAt == null
        ? null
        : Wire.instant(replacementDepartsAt!),
    'seatsFree': seatsFree,
    'rebill': rebill == null ? null : Wire.money(rebill!),
    'autoAccepted': autoAccepted,
    'seatsMoved': seatsMoved,
    'declineReason': declineReason,
  });

  factory ProtectionRequestDto.fromJson(
    Map<String, Object?> json,
  ) => ProtectionRequestDto(
    id: Wire.requireString(json['id'], 'id'),
    agreementId: Wire.requireString(json['agreementId'], 'agreementId'),
    counterpartyName: Wire.requireString(
      json['counterpartyName'],
      'counterpartyName',
    ),
    weAsked: json['weAsked'] as bool? ?? false,
    fromDepartureId: Wire.requireString(
      json['fromDepartureId'],
      'fromDepartureId',
    ),
    toDepartureId: Wire.requireString(json['toDepartureId'], 'toDepartureId'),
    seatsRequested: Wire.requireInt(json['seatsRequested'], 'seatsRequested'),
    state: Wire.requireString(json['state'], 'state'),
    requestedAt: Wire.readInstant(json['requestedAt'], field: 'requestedAt'),
    note: json['note'] as String?,
    routeCode: json['routeCode'] as String?,
    departsAt: json['departsAt'] == null
        ? null
        : Wire.readInstant(json['departsAt'], field: 'departsAt'),
    replacementDepartsAt: json['replacementDepartsAt'] == null
        ? null
        : Wire.readInstant(
            json['replacementDepartsAt'],
            field: 'replacementDepartsAt',
          ),
    seatsFree: json['seatsFree'] as int? ?? 0,
    rebill: json['rebill'] == null
        ? null
        : Wire.readMoney(json['rebill'], field: 'rebill'),
    autoAccepted: json['autoAccepted'] as bool? ?? false,
    seatsMoved: json['seatsMoved'] as int?,
    declineReason: json['declineReason'] as String?,
  );
}

/// Asking for room.
final class ProtectionRequestBody {
  const ProtectionRequestBody({
    required this.departureId,
    required this.replacementDepartureId,
    this.note,
  });

  /// The coach that has failed.
  final String departureId;

  /// The other company's departure being asked for. Named, never "whichever
  /// has room" — a departure nobody has looked at is not a plan.
  final String replacementDepartureId;

  final String? note;

  Map<String, Object?> toJson() => Wire.compact({
    'departureId': departureId,
    'replacementDepartureId': replacementDepartureId,
    'note': note,
  });

  factory ProtectionRequestBody.fromJson(Map<String, Object?> json) =>
      ProtectionRequestBody(
        departureId: Wire.requireString(json['departureId'], 'departureId'),
        replacementDepartureId: Wire.requireString(
          json['replacementDepartureId'],
          'replacementDepartureId',
        ),
        note: json['note'] as String?,
      );
}
