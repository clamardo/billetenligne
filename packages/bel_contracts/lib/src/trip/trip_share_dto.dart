import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// The link a traveller hands to somebody (ADR-0014 §2).
///
/// The **plaintext token exists once**, in the response that creates it. It is
/// stored as a hash, like a sign-in code, so a database dump is not a set of
/// working links into people's journeys. Asking again returns the same share
/// with no token — the traveller already has the link, and reissuing one would
/// leave a live link they cannot see to revoke.
final class TripShareDto {
  const TripShareDto({
    required this.expiresAt,
    required this.opens,
    required this.revoked,
    this.url,
  });

  /// Null on a read. Present only when this response is the one that minted
  /// it.
  final String? url;

  final DateTime expiresAt;

  /// "3 personnes ont ouvert ce lien." Somebody who shares a journey wants to
  /// know it arrived; somebody who shared it with the wrong group wants to
  /// know that too, while there is still time to revoke.
  final int opens;

  final bool revoked;

  Map<String, Object?> toJson() => Wire.compact({
    'url': url,
    'expiresAt': Wire.instant(expiresAt),
    'opens': opens,
    'revoked': revoked,
  });

  factory TripShareDto.fromJson(Map<String, Object?> json) => TripShareDto(
    url: json['url'] as String?,
    expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
    opens: json['opens'] as int? ?? 0,
    revoked: json['revoked'] as bool? ?? false,
  );
}

/// What a follower is shown, and the complete list of it.
///
/// Everything here is a fact about a **coach**. There is no seat, no
/// reference, no fare and no phone number, and there is no field for one —
/// ADR-0014 says the page never shows them, and the way to keep that true is
/// for the type not to be able to carry them.
final class FollowedTripDto {
  const FollowedTripDto({
    required this.operatorName,
    required this.routeCode,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.status,
    required this.tier,
    required this.progress,
    required this.expiresAt,
    this.reportedAt,
    this.checkpointName,
    this.disruptionKind,
    this.disruptionCauseKey,
    this.disruptionNote,
    this.revisedDepartsAt,
  });

  final String operatorName;
  final String routeCode;
  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;

  /// `scheduled` · `boarding` · `departed` · `arrived` · `cancelled`.
  final String status;

  /// `gps` · `checkpoint` · `schedule`. **Rendered**, not hidden: a page that
  /// smoothed an estimate into a live position would be the one dishonest
  /// thing in this feature.
  final String tier;

  /// 0 at the origin, 1 at the destination.
  final double progress;

  final DateTime expiresAt;

  final DateTime? reportedAt;
  final String? checkpointName;

  final String? disruptionKind;
  final String? disruptionCauseKey;

  /// The dispatcher's own words. The follower gets them too: somebody waiting
  /// at a station is exactly the person who otherwise phones the agency.
  final String? disruptionNote;

  final DateTime? revisedDepartsAt;

  bool get isEstimate => tier == 'schedule';
  bool get isDisrupted => disruptionKind != null;

  /// When the coach is actually expected, which is not always when it was
  /// scheduled.
  DateTime get expectedDeparture => revisedDepartsAt ?? departsAt;

  Map<String, Object?> toJson() => Wire.compact({
    'operatorName': operatorName,
    'routeCode': routeCode,
    'originCity': originCity,
    'destinationCity': destinationCity,
    'departsAt': Wire.instant(departsAt),
    'arrivesAt': Wire.instant(arrivesAt),
    'status': status,
    'tier': tier,
    'progress': progress,
    'expiresAt': Wire.instant(expiresAt),
    'reportedAt': reportedAt == null ? null : Wire.instant(reportedAt!),
    'checkpointName': checkpointName,
    'disruptionKind': disruptionKind,
    'disruptionCauseKey': disruptionCauseKey,
    'disruptionNote': disruptionNote,
    'revisedDepartsAt': revisedDepartsAt == null
        ? null
        : Wire.instant(revisedDepartsAt!),
  });

  factory FollowedTripDto.fromJson(Map<String, Object?> json) =>
      FollowedTripDto(
        operatorName: Wire.requireString(json['operatorName'], 'operatorName'),
        routeCode: Wire.requireString(json['routeCode'], 'routeCode'),
        originCity: Wire.requireString(json['originCity'], 'originCity'),
        destinationCity: Wire.requireString(
          json['destinationCity'],
          'destinationCity',
        ),
        departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
        arrivesAt: Wire.readInstant(json['arrivesAt'], field: 'arrivesAt'),
        status: Wire.requireString(json['status'], 'status'),
        tier: Wire.requireString(json['tier'], 'tier'),
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        expiresAt: Wire.readInstant(json['expiresAt'], field: 'expiresAt'),
        reportedAt: json['reportedAt'] == null
            ? null
            : Wire.readInstant(json['reportedAt'], field: 'reportedAt'),
        checkpointName: json['checkpointName'] as String?,
        disruptionKind: json['disruptionKind'] as String?,
        disruptionCauseKey: json['disruptionCauseKey'] as String?,
        disruptionNote: json['disruptionNote'] as String?,
        revisedDepartsAt: json['revisedDepartsAt'] == null
            ? null
            : Wire.readInstant(
                json['revisedDepartsAt'],
                field: 'revisedDepartsAt',
              ),
      );

  /// The tier as the domain names it, so a surface can switch on it rather
  /// than on a string.
  TrackingTier get trackingTier => switch (tier) {
    'gps' => TrackingTier.gps,
    'checkpoint' => TrackingTier.checkpoint,
    _ => TrackingTier.schedule,
  };
}

/// One place on the road, as the passenger's ticket lists it (J6).
final class JourneyStopDto {
  const JourneyStopDto({
    required this.name,
    required this.offsetMinutes,
    this.passedAt,
  });

  /// The station if the stop names one, the city otherwise — the name a
  /// passenger would use for where they just were.
  final String name;

  /// Minutes into the run. What puts the list in road order without the
  /// screen having to know anything about roads.
  final int offsetMinutes;

  /// The conductor's own clock, when somebody confirmed the coach past it.
  /// Null for everywhere still ahead.
  final DateTime? passedAt;

  bool get isBehind => passedAt != null;

  Map<String, Object?> toJson() => Wire.compact({
    'name': name,
    'offsetMinutes': offsetMinutes,
    'passedAt': passedAt == null ? null : Wire.instant(passedAt!),
  });

  factory JourneyStopDto.fromJson(Map<String, Object?> json) => JourneyStopDto(
    name: Wire.requireString(json['name'], 'name'),
    offsetMinutes: Wire.requireInt(json['offsetMinutes'], 'offsetMinutes'),
    passedAt: json['passedAt'] == null
        ? null
        : Wire.readInstant(json['passedAt'], field: 'passedAt'),
  );
}

/// Where the passenger's own coach has got to (J6).
///
/// The same three tiers a follower sees, read through the booking instead of
/// through a share token — a passenger holding a ticket needs no link to see
/// where their coach is.
///
/// **[tier] is not decoration and is not optional.** This screen must never
/// draw more confidence than the data has: a bar with no `schedule` label on
/// it is a claim that somebody reported something, and on the RN1 that claim
/// is usually false. ADR-0014 closes with the instruction to resist exactly
/// this, and the type carries the tier as a required field so a surface
/// cannot quietly stop rendering it.
///
/// Carries no operator, no route code and no cities: they came with the
/// booking, and a second copy is a copy that can disagree.
final class TripJourneyDto {
  const TripJourneyDto({
    required this.departsAt,
    required this.arrivesAt,
    required this.status,
    required this.tier,
    required this.progress,
    this.stops = const [],
    this.reportedAt,
    this.checkpointName,
    this.revisedDepartsAt,
  });

  final DateTime departsAt;
  final DateTime arrivesAt;

  /// `scheduled` · `delayed` · `boarding` · `departed` · `arrived` ·
  /// `cancelled`.
  final String status;

  /// `gps` · `checkpoint` · `schedule`.
  final String tier;

  /// 0 at the origin, 1 at the destination.
  final double progress;

  /// The road, in the order it runs, with what is behind marked.
  final List<JourneyStopDto> stops;

  /// When the underlying fact was true — the checkpoint tap. Null on
  /// `schedule`, which has no observation behind it.
  final DateTime? reportedAt;

  final String? checkpointName;

  /// The dispatcher's new time when a delay has been declared. The progress
  /// above is measured from it.
  final DateTime? revisedDepartsAt;

  bool get isEstimate => tier == 'schedule';

  DateTime get expectedDeparture => revisedDepartsAt ?? departsAt;

  TrackingTier get trackingTier => switch (tier) {
    'gps' => TrackingTier.gps,
    'checkpoint' => TrackingTier.checkpoint,
    _ => TrackingTier.schedule,
  };

  Map<String, Object?> toJson() => Wire.compact({
    'departsAt': Wire.instant(departsAt),
    'arrivesAt': Wire.instant(arrivesAt),
    'status': status,
    'tier': tier,
    'progress': progress,
    'stops': [for (final stop in stops) stop.toJson()],
    'reportedAt': reportedAt == null ? null : Wire.instant(reportedAt!),
    'checkpointName': checkpointName,
    'revisedDepartsAt': revisedDepartsAt == null
        ? null
        : Wire.instant(revisedDepartsAt!),
  });

  factory TripJourneyDto.fromJson(Map<String, Object?> json) => TripJourneyDto(
    departsAt: Wire.readInstant(json['departsAt'], field: 'departsAt'),
    arrivesAt: Wire.readInstant(json['arrivesAt'], field: 'arrivesAt'),
    status: Wire.requireString(json['status'], 'status'),
    tier: Wire.requireString(json['tier'], 'tier'),
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    stops: [
      for (final stop in (json['stops'] as List? ?? const []))
        JourneyStopDto.fromJson((stop as Map).cast<String, Object?>()),
    ],
    reportedAt: json['reportedAt'] == null
        ? null
        : Wire.readInstant(json['reportedAt'], field: 'reportedAt'),
    checkpointName: json['checkpointName'] as String?,
    revisedDepartsAt: json['revisedDepartsAt'] == null
        ? null
        : Wire.readInstant(json['revisedDepartsAt'], field: 'revisedDepartsAt'),
  );
}
