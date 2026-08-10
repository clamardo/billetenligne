import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// What the dispatcher declares, on the wire.
///
/// The kind and the cause travel as the domain enum's own names, so the
/// server parses them back into the same type the console validated against
/// (ADR-0004). A string the server accepts but the domain does not know is a
/// disruption nobody can render a sentence for.
final class DeclareDisruptionRequest {
  const DeclareDisruptionRequest({
    required this.kind,
    required this.cause,
    this.note,
    this.location,
    this.revisedDepartsAt,
    this.estimatedResolution,
  });

  final DisruptionKind kind;
  final DisruptionCause cause;
  final String? note;
  final String? location;
  final DateTime? revisedDepartsAt;
  final DateTime? estimatedResolution;

  Map<String, Object?> toJson() => Wire.compact({
    'kind': kind.name,
    'cause': cause.name,
    'note': note,
    'location': location,
    'revisedDepartsAt': revisedDepartsAt == null
        ? null
        : Wire.instant(revisedDepartsAt!),
    'estimatedResolution': estimatedResolution == null
        ? null
        : Wire.instant(estimatedResolution!),
  });

  factory DeclareDisruptionRequest.fromJson(Map<String, Object?> json) =>
      DeclareDisruptionRequest(
        kind: disruptionKindFromWire(Wire.requireString(json['kind'], 'kind')),
        cause: disruptionCauseFromWire(
          Wire.requireString(json['cause'], 'cause'),
        ),
        note: json['note'] as String?,
        location: json['location'] as String?,
        revisedDepartsAt: Wire.readInstantOrNull(
          json['revisedDepartsAt'],
          field: 'revisedDepartsAt',
        ),
        estimatedResolution: Wire.readInstantOrNull(
          json['estimatedResolution'],
          field: 'estimatedResolution',
        ),
      );
}

/// A disruption as everyone reads it: the dispatcher who declared it, the
/// traveller whose ticket it affects, and the follower of a shared trip link
/// who holds no account at all.
///
/// It carries **no prose** (ADR-0008). [kind] and [cause] are catalog keys in
/// all but name; [note] is the one field that is the operator's own words,
/// and it is theirs precisely because no catalog can hold "le pont de la
/// Loufoulakari est coupé".
final class DisruptionDto {
  const DisruptionDto({
    required this.id,
    required this.kind,
    required this.cause,
    required this.declaredAt,
    required this.marksInvoluntary,
    this.note,
    this.location,
    this.revisedDepartsAt,
    this.estimatedResolution,
    this.resolvedAt,
  });

  final String id;
  final DisruptionKind kind;
  final DisruptionCause cause;
  final DateTime declaredAt;

  /// Whether this exempts the affected bookings from fees and fare
  /// differences for good. Sent rather than recomputed, because it was frozen
  /// at declaration time — the threshold can change; what somebody was
  /// promised cannot.
  final bool marksInvoluntary;

  final String? note;
  final String? location;
  final DateTime? revisedDepartsAt;
  final DateTime? estimatedResolution;
  final DateTime? resolvedAt;

  bool get isOpen => resolvedAt == null;

  /// The catalog key for the headline, e.g. `disruption.kind.delay`.
  String get kindKey => 'disruption.kind.${kind.name}';
  String get causeKey => 'disruption.cause.${cause.name}';

  Map<String, Object?> toJson() => Wire.compact({
    'id': id,
    'kind': kind.name,
    'cause': cause.name,
    'declaredAt': Wire.instant(declaredAt),
    'marksInvoluntary': marksInvoluntary,
    'note': note,
    'location': location,
    'revisedDepartsAt': revisedDepartsAt == null
        ? null
        : Wire.instant(revisedDepartsAt!),
    'estimatedResolution': estimatedResolution == null
        ? null
        : Wire.instant(estimatedResolution!),
    'resolvedAt': resolvedAt == null ? null : Wire.instant(resolvedAt!),
  });

  factory DisruptionDto.fromJson(Map<String, Object?> json) => DisruptionDto(
    id: Wire.requireString(json['id'], 'id'),
    kind: disruptionKindFromWire(Wire.requireString(json['kind'], 'kind')),
    cause: disruptionCauseFromWire(Wire.requireString(json['cause'], 'cause')),
    declaredAt: Wire.readInstant(json['declaredAt'], field: 'declaredAt'),
    marksInvoluntary: json['marksInvoluntary'] as bool? ?? false,
    note: json['note'] as String?,
    location: json['location'] as String?,
    revisedDepartsAt: Wire.readInstantOrNull(
      json['revisedDepartsAt'],
      field: 'revisedDepartsAt',
    ),
    estimatedResolution: Wire.readInstantOrNull(
      json['estimatedResolution'],
      field: 'estimatedResolution',
    ),
    resolvedAt: Wire.readInstantOrNull(json['resolvedAt'], field: 'resolvedAt'),
  );
}

/// What a declaration did, answered to the dispatcher who made it.
///
/// The counts are the point. "Signalé" tells a dispatcher nothing; "42
/// passagers prévenus" tells them the message went out and roughly how much
/// of their morning just changed.
final class DeclaredDisruptionDto {
  const DeclaredDisruptionDto({
    required this.disruption,
    required this.departureId,
    required this.bookingsAffected,
    required this.departureStatus,
  });

  final DisruptionDto disruption;
  final String departureId;

  /// Confirmed bookings on the departure at declaration time.
  final int bookingsAffected;

  /// What the departure now reads as on the board, or null when the
  /// declaration deliberately left it alone — a coach already on the road is
  /// not put back into "has not left yet".
  final String? departureStatus;

  Map<String, Object?> toJson() => Wire.compact({
    'disruption': disruption.toJson(),
    'departureId': departureId,
    'bookingsAffected': bookingsAffected,
    'departureStatus': departureStatus,
  });

  factory DeclaredDisruptionDto.fromJson(Map<String, Object?> json) =>
      DeclaredDisruptionDto(
        disruption: DisruptionDto.fromJson(
          (json['disruption'] as Map).cast<String, Object?>(),
        ),
        departureId: Wire.requireString(json['departureId'], 'departureId'),
        bookingsAffected: Wire.requireInt(
          json['bookingsAffected'],
          'bookingsAffected',
        ),
        departureStatus: json['departureStatus'] as String?,
      );
}

/// Wire name → enum, refusing anything else.
///
/// No fallback, deliberately: a kind we cannot understand must not quietly
/// become a delay, because a delay is the one kind that entitles nobody to
/// anything. Refusing the request is the honest failure.
DisruptionKind disruptionKindFromWire(String value) =>
    Wire.readEnum(value, DisruptionKind.values, field: 'kind');

/// An unknown cause becomes [DisruptionCause.other], and the asymmetry with
/// the kind above is the point. The cause feeds statistics; the kind decides
/// entitlements. Losing one to a fallback is a slightly wrong chart; losing
/// the other is a passenger told the wrong thing.
DisruptionCause disruptionCauseFromWire(String value) => Wire.readEnum(
  value,
  DisruptionCause.values,
  field: 'cause',
  fallback: DisruptionCause.other,
);

/// Sending a different coach (`08-disruption.md` §2.2 option ①).
final class RescueCoachRequest {
  const RescueCoachRequest({required this.vehicleId, this.note});

  final String vehicleId;
  final String? note;

  Map<String, Object?> toJson() =>
      Wire.compact({'vehicleId': vehicleId, 'note': note});

  factory RescueCoachRequest.fromJson(Map<String, Object?> json) =>
      RescueCoachRequest(
        vehicleId: Wire.requireString(json['vehicleId'], 'vehicleId'),
        note: json['note'] as String?,
      );
}

/// Where one passenger sat, and where they will sit.
final class SeatMoveDto {
  const SeatMoveDto({required this.from, required this.to});

  final String from;
  final String to;

  bool get isUnchanged => from == to;

  Map<String, Object?> toJson() => {'from': from, 'to': to};

  factory SeatMoveDto.fromJson(Map<String, Object?> json) => SeatMoveDto(
    from: Wire.requireString(json['from'], 'from'),
    to: Wire.requireString(json['to'], 'to'),
  );
}

/// What sending a rescue coach did.
///
/// The moves travel in full, including the seats that did not change. A
/// dispatcher reading "3 moved" needs the other thirty-nine accounted for
/// before they will believe the three.
final class RescueAppliedDto {
  const RescueAppliedDto({
    required this.departureId,
    required this.registration,
    required this.moves,
    required this.passengersTold,
    required this.ticketsReissued,
    required this.holdsReleased,
  });

  final String departureId;
  final String registration;
  final List<SeatMoveDto> moves;
  final int passengersTold;
  final int ticketsReissued;

  /// Somebody mid-checkout whose seat may not exist on the new coach. Told,
  /// not hidden: they have to choose again.
  final int holdsReleased;

  int get moved => moves.where((m) => !m.isUnchanged).length;

  Map<String, Object?> toJson() => {
    'departureId': departureId,
    'registration': registration,
    'moves': [for (final m in moves) m.toJson()],
    'passengersTold': passengersTold,
    'ticketsReissued': ticketsReissued,
    'holdsReleased': holdsReleased,
  };

  factory RescueAppliedDto.fromJson(
    Map<String, Object?> json,
  ) => RescueAppliedDto(
    departureId: Wire.requireString(json['departureId'], 'departureId'),
    registration: Wire.requireString(json['registration'], 'registration'),
    moves: Wire.readList(json['moves'], SeatMoveDto.fromJson, field: 'moves'),
    passengersTold: Wire.requireInt(json['passengersTold'], 'passengersTold'),
    ticketsReissued: Wire.requireInt(
      json['ticketsReissued'],
      'ticketsReissued',
    ),
    holdsReleased: Wire.requireInt(json['holdsReleased'], 'holdsReleased'),
  );
}

/// Moving the passengers onto another departure (`08-disruption.md` §2.2
/// option ②).
final class RebookRequest {
  const RebookRequest({required this.replacementDepartureId, this.note});

  final String replacementDepartureId;
  final String? note;

  Map<String, Object?> toJson() => Wire.compact({
    'replacementDepartureId': replacementDepartureId,
    'note': note,
  });

  factory RebookRequest.fromJson(Map<String, Object?> json) => RebookRequest(
    replacementDepartureId: Wire.requireString(
      json['replacementDepartureId'],
      'replacementDepartureId',
    ),
    note: json['note'] as String?,
  );
}

/// One booking, moved onto the replacement.
final class RebookedPartyDto {
  const RebookedPartyDto({
    required this.bookingId,
    required this.ref,
    required this.seatLabels,
  });

  final String bookingId;
  final String ref;
  final List<String> seatLabels;

  Map<String, Object?> toJson() => {
    'bookingId': bookingId,
    'ref': ref,
    'seatLabels': seatLabels,
  };

  factory RebookedPartyDto.fromJson(Map<String, Object?> json) =>
      RebookedPartyDto(
        bookingId: Wire.requireString(json['bookingId'], 'bookingId'),
        ref: Wire.requireString(json['ref'], 'ref'),
        seatLabels: [
          for (final label in (json['seatLabels'] as List? ?? const []))
            label as String,
        ],
      );
}

/// What the rebooking wave did.
///
/// **[passengersLeft] travels even when it is zero.** Partial coverage is the
/// normal outcome of moving forty-two people onto a departure with eighteen
/// free seats, and a client that had to infer "24 still stranded" from a
/// missing field would eventually infer it wrongly.
final class RebookingAppliedDto {
  const RebookingAppliedDto({
    required this.departureId,
    required this.replacementDepartureId,
    required this.replacementDepartsAt,
    required this.moved,
    required this.passengersMoved,
    required this.passengersLeft,
  });

  final String departureId;
  final String replacementDepartureId;
  final DateTime replacementDepartsAt;
  final List<RebookedPartyDto> moved;
  final int passengersMoved;
  final int passengersLeft;

  bool get coversEverybody => passengersLeft == 0;

  Map<String, Object?> toJson() => {
    'departureId': departureId,
    'replacementDepartureId': replacementDepartureId,
    'replacementDepartsAt': Wire.instant(replacementDepartsAt),
    'moved': [for (final party in moved) party.toJson()],
    'passengersMoved': passengersMoved,
    'passengersLeft': passengersLeft,
  };

  factory RebookingAppliedDto.fromJson(Map<String, Object?> json) =>
      RebookingAppliedDto(
        departureId: Wire.requireString(json['departureId'], 'departureId'),
        replacementDepartureId: Wire.requireString(
          json['replacementDepartureId'],
          'replacementDepartureId',
        ),
        replacementDepartsAt: Wire.readInstant(
          json['replacementDepartsAt'],
          field: 'replacementDepartsAt',
        ),
        moved: [
          for (final party in (json['moved'] as List? ?? const []))
            RebookedPartyDto.fromJson(party as Map<String, Object?>),
        ],
        passengersMoved: Wire.requireInt(
          json['passengersMoved'],
          'passengersMoved',
        ),
        passengersLeft: Wire.requireInt(
          json['passengersLeft'],
          'passengersLeft',
        ),
      );
}
