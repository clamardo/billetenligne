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
    this.change = const ChangePolicyDto(),
    this.missed = const MissedPolicyDto(),
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

  /// What it costs to move to another departure, under the same version
  /// stamp. Defaulted rather than required: a server that predates the change
  /// terms answers without them, and D-08's numbers are the right thing to
  /// assume in that case — they are what every policy stored before this
  /// field existed actually behaves as.
  final ChangePolicyDto change;

  /// What happens to somebody who was late. Defaulted to "not offered",
  /// which is what every policy stored before this field existed behaves as —
  /// and the only honest default, since honouring a missed ticket is a
  /// commercial promise no platform should make on a company's behalf.
  final MissedPolicyDto missed;

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

  /// The change terms as the domain object, so this preview and the
  /// traveller's list of departures are priced by the same code.
  ChangePolicy changeToDomain() => change.toDomain();

  /// The missed-departure terms as the domain object, so the console's
  /// preview and the counter's quote are written by the same function.
  MissedPolicy missedToDomain() => missed.toDomain();

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'name': name,
    'tiers': [for (final t in tiers) t.toJson()],
    'destination': destination,
    'processingHours': processingHours,
    'refundServiceFee': refundServiceFee,
    'nonRefundableFares': nonRefundableFares,
    'change': change.toJson(),
    'missed': missed.toJson(),
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
    change: ChangePolicyDto.fromJson(
      (json['change'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    missed: MissedPolicyDto.fromJson(
      (json['missed'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    isDefault: json['isDefault'] as bool? ?? false,
    bookingCount: json['bookingCount'] as int? ?? 0,
  );

  factory RefundPolicyDto.fromDomain(
    RefundPolicy policy, {
    required String name,
    required bool isDefault,
    ChangePolicy change = ChangePolicy.standard,
    MissedPolicy missed = MissedPolicy.notOffered,
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
    change: ChangePolicyDto.fromDomain(change),
    missed: MissedPolicyDto.fromDomain(missed),
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

/// What moving to another departure costs, on the wire.
///
/// Three numbers, and they travel in the units the operator answered in —
/// hours for the two windows, basis points for the rate — because the console
/// asks for hours and percent, and converting twice on the way down is how a
/// 10% fee becomes a 1000% one.
final class ChangePolicyDto {
  const ChangePolicyDto({
    this.freeBeforeHours = 24,
    this.feeBps = 1000,
    this.cutoffHours = 2,
  });

  final int freeBeforeHours;

  /// Basis points, integer. 1000 = 10%, and no float ever touches a fare.
  final int feeBps;

  final int cutoffHours;

  ChangePolicy toDomain() => ChangePolicy(
    freeBefore: Duration(hours: freeBeforeHours),
    feeBps: feeBps,
    cutoff: Duration(hours: cutoffHours),
  );

  Map<String, Object?> toJson() => {
    'freeBeforeHours': freeBeforeHours,
    'feeBps': feeBps,
    'cutoffHours': cutoffHours,
  };

  factory ChangePolicyDto.fromJson(Map<String, Object?> json) =>
      ChangePolicyDto(
        freeBeforeHours: json['freeBeforeHours'] as int? ?? 24,
        feeBps: json['feeBps'] as int? ?? 1000,
        cutoffHours: json['cutoffHours'] as int? ?? 2,
      );

  factory ChangePolicyDto.fromDomain(ChangePolicy policy) => ChangePolicyDto(
    freeBeforeHours: policy.freeBefore.inHours,
    feeBps: policy.feeBps,
    cutoffHours: policy.cutoff.inHours,
  );
}

/// What happens to somebody who was late, on the wire.
///
/// Two numbers, in the units the operator answered in: hours for the window,
/// basis points for the fee. Zero and zero is "not offered", and it is the
/// default for the same reason it is the column default — a platform that
/// promised a company's seats away by omission would be making a commercial
/// commitment nobody agreed to.
final class MissedPolicyDto {
  const MissedPolicyDto({this.windowHours = 0, this.feeBps = 0});

  final int windowHours;

  /// Basis points, integer. 2500 = 25%, and no float ever touches a fare.
  final int feeBps;

  MissedPolicy toDomain() => MissedPolicy(
    window: Duration(hours: windowHours),
    feeBps: feeBps,
  );

  Map<String, Object?> toJson() => {
    'windowHours': windowHours,
    'feeBps': feeBps,
  };

  factory MissedPolicyDto.fromJson(Map<String, Object?> json) =>
      MissedPolicyDto(
        windowHours: json['windowHours'] as int? ?? 0,
        feeBps: json['feeBps'] as int? ?? 0,
      );

  factory MissedPolicyDto.fromDomain(MissedPolicy policy) => MissedPolicyDto(
    windowHours: policy.window.inHours,
    feeBps: policy.feeBps,
  );
}
