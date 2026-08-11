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
