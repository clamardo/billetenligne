import 'package:bel_domain/bel_domain.dart';

import '../json/json_codec.dart';

/// One stored version of one refund policy, on the wire.
///
/// The DTO carries the **structured terms**, never the prose. `RefundPolicy`
/// in the domain renders the sentences, and both the console and the traveller
/// app call it — so the policy a traveller reads before paying and the policy
/// the server executes at cancellation are the same object rendered twice,
/// which is the whole of ADR-0015 rule 3. Sending sentences down the wire
/// instead would put a second copy of the rules in the response, drifting the
/// day somebody edits one and not the other.
final class RefundPolicyDto {
  const RefundPolicyDto({
    required this.id,
    required this.version,
    required this.name,
    required this.tiers,
    required this.destination,
    required this.processingHours,
    required this.refundServiceFee,
    required this.nonRefundableFares,
    required this.isDefault,
    this.bookingCount = 0,
  });

  final String id;
  final int version;
  final String name;
  final List<RefundTierDto> tiers;
  final String destination;
  final int processingHours;
  final bool refundServiceFee;
  final List<String> nonRefundableFares;

  /// Whether new sales are stamped with this version. At most one version of
  /// one policy is true.
  final bool isDefault;

  /// Bookings already sold under this exact version — the honest answer to
  /// "can I just change this?". Every one of them is entitled to these terms.
  final int bookingCount;

  String get displayName => '$name · v$version';

  /// The domain object, so the console's preview and the traveller's terms
  /// screen are rendered by the same function the server executes.
  RefundPolicy toDomain() => RefundPolicy(
    id: id,
    version: version,
    tiers: [for (final t in tiers) t.toDomain()],
    destination: RefundDestination.values.firstWhere(
      (d) => d.name == destination,
      orElse: () => RefundDestination.source,
    ),
    processingWindow: Duration(hours: processingHours),
    refundServiceFee: refundServiceFee,
    nonRefundableFareCodes: nonRefundableFares.toSet(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'name': name,
    'tiers': [for (final t in tiers) t.toJson()],
    'destination': destination,
    'processingHours': processingHours,
    'refundServiceFee': refundServiceFee,
    'nonRefundableFares': nonRefundableFares,
    'isDefault': isDefault,
    'bookingCount': bookingCount,
  };

  factory RefundPolicyDto.fromJson(
    Map<String, Object?> json,
  ) => RefundPolicyDto(
    id: Wire.requireString(json['id'], 'id'),
    version: Wire.requireInt(json['version'], 'version'),
    name: Wire.requireString(json['name'], 'name'),
    tiers: Wire.readList(json['tiers'], RefundTierDto.fromJson, field: 'tiers'),
    destination: json['destination'] as String? ?? 'source',
    processingHours: json['processingHours'] as int? ?? 72,
    refundServiceFee: json['refundServiceFee'] as bool? ?? false,
    nonRefundableFares: [
      for (final f in (json['nonRefundableFares'] as List? ?? const [])) '$f',
    ],
    isDefault: json['isDefault'] as bool? ?? false,
    bookingCount: json['bookingCount'] as int? ?? 0,
  );

  factory RefundPolicyDto.fromDomain(
    RefundPolicy policy, {
    required String name,
    required bool isDefault,
    int bookingCount = 0,
  }) => RefundPolicyDto(
    id: policy.id,
    version: policy.version,
    name: name,
    tiers: [for (final t in policy.tiers) RefundTierDto.fromDomain(t)],
    destination: policy.destination.name,
    processingHours: policy.processingWindow.inHours,
    refundServiceFee: policy.refundServiceFee,
    nonRefundableFares: policy.nonRefundableFareCodes.toList()..sort(),
    isDefault: isDefault,
    bookingCount: bookingCount,
  );
}

/// One band of the timeline: "at least 48 h before departure → 90%".
///
/// Lead time travels in **minutes** rather than hours, because an operator
/// who wants "up to 90 minutes before" should not be rounded into two hours
/// by the wire format.
final class RefundTierDto {
  const RefundTierDto({
    required this.minLeadTimeMinutes,
    required this.rateBps,
    this.flatFeeMinor = 0,
  });

  final int minLeadTimeMinutes;

  /// Basis points, integer. 10000 = 100%, and no float ever touches a fare.
  final int rateBps;

  final int flatFeeMinor;

  RefundTier toDomain() => RefundTier(
    minLeadTime: Duration(minutes: minLeadTimeMinutes),
    rateBps: rateBps,
    flatFeeMinor: flatFeeMinor,
  );

  Map<String, Object?> toJson() => Wire.compact({
    'minLeadTimeMinutes': minLeadTimeMinutes,
    'rateBps': rateBps,
    'flatFeeMinor': flatFeeMinor == 0 ? null : flatFeeMinor,
  });

  factory RefundTierDto.fromJson(Map<String, Object?> json) => RefundTierDto(
    minLeadTimeMinutes: Wire.requireInt(
      json['minLeadTimeMinutes'],
      'minLeadTimeMinutes',
    ),
    rateBps: Wire.requireInt(json['rateBps'], 'rateBps'),
    flatFeeMinor: json['flatFeeMinor'] as int? ?? 0,
  );

  factory RefundTierDto.fromDomain(RefundTier tier) => RefundTierDto(
    minLeadTimeMinutes: tier.minLeadTime.inMinutes,
    rateBps: tier.rateBps,
    flatFeeMinor: tier.flatFeeMinor,
  );
}
