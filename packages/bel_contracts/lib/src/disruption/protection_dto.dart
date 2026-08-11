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
