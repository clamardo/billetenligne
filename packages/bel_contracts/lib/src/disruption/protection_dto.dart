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
    required this.counterpartyName,
    required this.weAsked,
    this.agreementId,
    this.callId,
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

  /// The authority behind the movement. **Exactly one is set**: an agreement
  /// carries a negotiated discount, an open call carries the price it was
  /// broadcast at. A client that wants to know which kind of rescue this was
  /// asks which one is present rather than reading a `kind` string that could
  /// disagree with the ids beside it.
  final String? agreementId;
  final String? callId;

  final String counterpartyName;

  /// Whether this is ours to chase or ours to answer.
  final bool weAsked;

  /// Nobody was asked in particular: it went out to the road.
  bool get wasOpenCall => callId != null;

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
    'callId': callId,
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
    agreementId: json['agreementId'] as String?,
    callId: json['callId'] as String?,
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

/// An open call for room, as both consoles read it (`08-disruption.md` §5).
///
/// The same row serves the company asking and the companies who might answer,
/// with [weOpened] deciding which of the two screens it is drawn on. One DTO
/// rather than an outbound and an inbound one, because they carry the same
/// facts and a second shape would be a second thing to keep in step.
final class OpenCallDto {
  const OpenCallDto({
    required this.id,
    required this.sendingOperatorName,
    required this.weOpened,
    required this.fromDepartureId,
    required this.originCity,
    required this.destinationCity,
    required this.seatsRequested,
    required this.rebillPerSeat,
    required this.state,
    required this.openedAt,
    required this.expiresAt,
    this.note,
    this.departsAt,
    this.closedAt,
  });

  final String id;

  /// Named, because an operator deciding whether to take forty-two strangers
  /// is deciding partly on who is asking.
  final String sendingOperatorName;

  /// Ours to chase, or ours to answer.
  final bool weOpened;

  final String fromDepartureId;
  final String originCity;
  final String destinationCity;
  final int seatsRequested;

  /// Per seat, in the broken departure's own currency.
  final Money rebillPerSeat;

  /// `open` · `answered` · `withdrawn` · `expired`.
  final String state;

  final DateTime openedAt;

  /// A call with no end is a call still on somebody's console next week.
  final DateTime expiresAt;

  final String? note;
  final DateTime? departsAt;
  final DateTime? closedAt;

  bool get isOpen => state == 'open';

  /// What the whole coach-load is worth, which is the figure an operator
  /// decides on. Per seat is what the terms are; this is what it is worth.
  Money get rebillTotal => rebillPerSeat.multiply(seatsRequested);

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'sendingOperatorName': sendingOperatorName,
    'weOpened': weOpened,
    'fromDepartureId': fromDepartureId,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'seatsRequested': seatsRequested,
    'rebillPerSeat': Wire.money(rebillPerSeat),
    'state': state,
    'openedAt': Wire.instant(openedAt),
    'expiresAt': Wire.instant(expiresAt),
    'note': note,
    'departsAt': departsAt == null ? null : Wire.instant(departsAt!),
    'closedAt': closedAt == null ? null : Wire.instant(closedAt!),
  });

  factory OpenCallDto.fromJson(Map<String, Object?> json) => OpenCallDto(
    id: Wire.requireString(json['id'], 'id'),
    sendingOperatorName: Wire.requireString(
      json['sendingOperatorName'],
      'sendingOperatorName',
    ),
    weOpened: json['weOpened'] as bool? ?? false,
    fromDepartureId: Wire.requireString(
      json['fromDepartureId'],
      'fromDepartureId',
    ),
    originCity: Wire.requireString(json['originCity'], 'originCity'),
    destinationCity: Wire.requireString(
      json['destinationCity'],
      'destinationCity',
    ),
    seatsRequested: Wire.requireInt(json['seatsRequested'], 'seatsRequested'),
    rebillPerSeat: Wire.readMoney(
      json['rebillPerSeat'],
      field: 'rebillPerSeat',
    ),
    state: Wire.requireString(json['state'], 'state'),
    openedAt: Wire.readInstant(json['openedAt'], field: 'openedAt'),
    expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
    note: json['note'] as String?,
    departsAt: json['departsAt'] == null
        ? null
        : Wire.readInstant(json['departsAt'], field: 'departsAt'),
    closedAt: json['closedAt'] == null
        ? null
        : Wire.readInstant(json['closedAt'], field: 'closedAt'),
  );
}

/// The inbox, and whether this operator is even in it.
///
/// [receiving] travels with the list so an empty inbox can say which kind of
/// empty it is: *nobody needs help right now* and *you never said yes* are the
/// same zero rows and completely different screens.
final class OpenCallsDto {
  const OpenCallsDto({required this.receiving, required this.calls});

  final bool receiving;
  final List<OpenCallDto> calls;

  Map<String, Object?> toJson() => {
    'receiving': receiving,
    'calls': [for (final c in calls) c.toJson()],
  };

  factory OpenCallsDto.fromJson(Map<String, Object?> json) => OpenCallsDto(
    receiving: json['receiving'] as bool? ?? false,
    calls: [
      for (final c in (json['calls'] as List? ?? const []))
        OpenCallDto.fromJson((c as Map).cast<String, Object?>()),
    ],
  );
}

/// Broadcasting for room.
final class OpenCallBody {
  const OpenCallBody({
    required this.departureId,
    this.windowMinutes,
    this.note,
  });

  /// The coach that has failed.
  final String departureId;

  /// How long the call stays live. Omitted means the server's own window —
  /// the client does not get to keep one open all week.
  final int? windowMinutes;

  final String? note;

  Map<String, Object?> toJson() => Wire.compact({
    'departureId': departureId,
    'windowMinutes': windowMinutes,
    'note': note,
  });

  factory OpenCallBody.fromJson(Map<String, Object?> json) => OpenCallBody(
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    windowMinutes: json['windowMinutes'] as int?,
    note: json['note'] as String?,
  );
}

/// Answering one, with a departure of our own.
final class AnswerCallBody {
  const AnswerCallBody({required this.replacementDepartureId, this.note});

  /// Named, never "whichever has room": a departure nobody has looked at is
  /// not a plan, and this one is about to carry somebody else's passengers.
  final String replacementDepartureId;

  final String? note;

  Map<String, Object?> toJson() => Wire.compact({
    'replacementDepartureId': replacementDepartureId,
    'note': note,
  });

  factory AnswerCallBody.fromJson(Map<String, Object?> json) => AnswerCallBody(
    replacementDepartureId: Wire.requireString(
      json['replacementDepartureId'],
      'replacementDepartureId',
    ),
    note: json['note'] as String?,
  );
}

/// Opting in or out of receiving open calls.
final class ReceiveOpenCallsBody {
  const ReceiveOpenCallsBody({required this.receiving});

  final bool receiving;

  Map<String, Object?> toJson() => {'receiving': receiving};

  factory ReceiveOpenCallsBody.fromJson(Map<String, Object?> json) =>
      ReceiveOpenCallsBody(receiving: json['receiving'] as bool? ?? false);
}
