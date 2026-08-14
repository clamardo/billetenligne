import 'package:bel_platform/bel_platform.dart';

/// Where a refund goes. Configured by the operator (ADR-0015).
///
/// [agencyCash] is not an edge case here: for a business whose treasury is
/// physical cash, requiring the traveller at the counter is a completely
/// reasonable stance. It is legitimate — but it must be disclosed *before*
/// purchase, never discovered at cancellation.
enum RefundDestination { source, agencyCash, creditNote, travellerChoice }

/// One band of the refund timeline: "at least 48 h before departure → 100%".
final class RefundTier {
  const RefundTier({
    required this.minLeadTime,
    required this.rateBps,
    this.flatFeeMinor = 0,
  });

  final Duration minLeadTime;

  /// Basis points. 10000 = 100%. Integer, so no float drift.
  final int rateBps;

  final int flatFeeMinor;
}

/// A versioned, operator-authored refund policy.
///
/// **Immutable and versioned by design.** A booking stores the policy version
/// it was sold under and is judged by that version forever — changing
/// tomorrow's policy must never change yesterday's customer's entitlement.
/// That is the single most important rule in ADR-0015.
final class RefundPolicy {
  const RefundPolicy({
    required this.id,
    required this.version,
    required this.tiers,
    this.destination = RefundDestination.source,
    this.processingWindow = const Duration(hours: 72),
    this.refundServiceFee = false,
    this.nonRefundableFareCodes = const {},
  });

  final String id;
  final int version;

  /// Ordered by lead time, longest first.
  final List<RefundTier> tiers;

  final RefundDestination destination;
  final Duration processingWindow;
  final bool refundServiceFee;
  final Set<String> nonRefundableFareCodes;

  /// Whether these tiers can be evaluated at all.
  ///
  /// Checked before a policy is stored rather than when a refund is quoted,
  /// because the failure mode is silent: tiers are matched **in order** and
  /// the first one whose lead time fits wins, so a list written shortest-first
  /// answers every request with its most generous band. Nobody notices until
  /// the month's refunds are counted.
  bool get isWellFormed {
    for (var i = 0; i < tiers.length; i++) {
      final tier = tiers[i];
      if (tier.rateBps < 0 || tier.rateBps > 10000) return false;
      if (tier.flatFeeMinor < 0) return false;
      if (tier.minLeadTime.isNegative) return false;
      if (i > 0 && tier.minLeadTime >= tiers[i - 1].minLeadTime) return false;
    }
    return processingWindow >= Duration.zero;
  }

  /// The policy as sentences, as translation keys rather than prose.
  ///
  /// ADR-0015 rule 3: **operators do not write policy text.** They answer the
  /// wizard's questions and we render the copy from the structured data, in
  /// every language, which is what guarantees the policy shown to a traveller
  /// and the policy executed by the server are the same object. A free-text
  /// field beside a tier table is how "the app said 90% and they paid 50%"
  /// becomes a dispute nobody can settle.
  ///
  /// Encoded `key|arg|arg` and rendered `a1`, `a2` — the same convention as
  /// notices (ADR-0008), so one catalog serves the console, the app and the
  /// email.
  List<String> describe() {
    final lines = <String>[];

    if (tiers.isEmpty) {
      lines.add('policy.line.noRefund');
    } else {
      for (final tier in tiers) {
        final hours = tier.minLeadTime.inHours;
        final percent = tier.rateBps ~/ 100;
        lines.add(switch (tier) {
          _ when tier.flatFeeMinor > 0 =>
            'policy.line.tierWithFee|$hours|$percent|${tier.flatFeeMinor}',
          _ when tier.rateBps == 10000 => 'policy.line.tierFull|$hours',
          _ => 'policy.line.tier|$hours|$percent',
        });
      }
      // The band below the last tier is the one travellers actually hit, and
      // it is the one a tier table never states. Saying it out loud is the
      // difference between a policy somebody read and a policy somebody
      // discovered.
      lines.add('policy.line.after|${tiers.last.minLeadTime.inHours}');
    }

    lines.add('policy.line.destination.${destination.name}');
    if (destination != RefundDestination.agencyCash) {
      lines.add('policy.line.window|${processingWindow.inHours}');
    }
    lines.add(
      refundServiceFee ? 'policy.line.feeRefunded' : 'policy.line.feeKept',
    );
    if (nonRefundableFareCodes.isNotEmpty) {
      final codes = nonRefundableFareCodes.toList()..sort();
      lines.add('policy.line.nonRefundable|${codes.join(", ")}');
    }

    // Last, and never optional. An operator cannot configure its way out of
    // its own breakdown (ADR-0015 rule 4), and a traveller reading the terms
    // should see the floor beneath them.
    lines.add('policy.line.platformFloor');
    return lines;
  }

  static RefundPolicy souple({String id = 'preset.souple'}) =>
      const RefundPolicy(
        id: 'preset.souple',
        version: 1,
        tiers: [
          RefundTier(minLeadTime: Duration(hours: 24), rateBps: 10000),
          RefundTier(minLeadTime: Duration(hours: 2), rateBps: 5000),
        ],
      );

  static RefundPolicy standard() => const RefundPolicy(
    id: 'preset.standard',
    version: 1,
    tiers: [
      RefundTier(minLeadTime: Duration(hours: 48), rateBps: 9000),
      RefundTier(minLeadTime: Duration(hours: 24), rateBps: 5000),
    ],
  );

  static RefundPolicy strict() =>
      const RefundPolicy(id: 'preset.strict', version: 1, tiers: []);
}

/// What the traveller will actually receive, and when.
final class RefundQuote {
  const RefundQuote({
    required this.faceValue,
    required this.serviceFee,
    required this.refundable,
    required this.retained,
    required this.destination,
    required this.processingWindow,
    required this.rateBps,
    required this.involuntary,
  });

  final Money faceValue;
  final Money serviceFee;

  /// What the traveller receives.
  final Money refundable;

  /// What is kept — fees plus the non-refunded share.
  final Money retained;

  final RefundDestination destination;
  final Duration processingWindow;
  final int rateBps;

  /// True when the operator caused this (breakdown, cancellation, long delay).
  /// Involuntary refunds bypass the policy entirely — platform floor.
  final bool involuntary;
}

sealed class RefundFailure extends DomainFailure {
  const RefundFailure();
}

final class OutsideRefundWindow extends RefundFailure {
  const OutsideRefundWindow();
  @override
  String get code => 'refund.outside_window';
}

final class FareNotRefundable extends RefundFailure {
  const FareNotRefundable(this.fareCode);
  final String fareCode;
  @override
  String get code => 'refund.fare_not_refundable';
  @override
  Map<String, Object?> get params => {'fareCode': fareCode};
}

final class AlreadyDeparted extends RefundFailure {
  const AlreadyDeparted();
  @override
  String get code => 'refund.already_departed';
}

/// The one function that both the app and the server call.
///
/// The Flutter app calls it to render "Vous recevrez 9 000 FCFA"; the API
/// calls it to actually issue the refund. They cannot disagree, because they
/// are the same code (ADR-0004). This is the whole argument for Dart
/// end-to-end, expressed in one function.
Result<RefundQuote, RefundFailure> quoteRefund({
  required Money faceValue,
  required Money serviceFee,
  required DateTime departsAt,
  required DateTime now,
  required RefundPolicy policy,
  String fareCode = 'standard',
  bool operatorCaused = false,
}) {
  // Platform floor (ADR-0015 rule 4): an operator cannot configure its way
  // out of its own failure. Full refund to source, no fee, no exceptions.
  if (operatorCaused) {
    final total = faceValue + serviceFee;
    return Ok(
      RefundQuote(
        faceValue: faceValue,
        serviceFee: serviceFee,
        refundable: total,
        retained: Money.zero(faceValue.currency),
        destination: RefundDestination.source,
        processingWindow: const Duration(hours: 72),
        rateBps: 10000,
        involuntary: true,
      ),
    );
  }

  if (!departsAt.isAfter(now)) return const Err(AlreadyDeparted());

  if (policy.nonRefundableFareCodes.contains(fareCode)) {
    return Err(FareNotRefundable(fareCode));
  }

  final lead = departsAt.difference(now);

  RefundTier? matched;
  for (final tier in policy.tiers) {
    if (lead >= tier.minLeadTime) {
      matched = tier;
      break;
    }
  }

  if (matched == null) return const Err(OutsideRefundWindow());

  final gross = faceValue.percentBps(matched.rateBps);
  final afterFlatFee = (gross - Money(matched.flatFeeMinor, faceValue.currency))
      .clampToZero();
  final refundable = policy.refundServiceFee
      ? afterFlatFee + serviceFee
      : afterFlatFee;
  final retained = (faceValue + serviceFee) - refundable;

  return Ok(
    RefundQuote(
      faceValue: faceValue,
      serviceFee: serviceFee,
      refundable: refundable,
      retained: retained,
      destination: policy.destination,
      processingWindow: policy.processingWindow,
      rateBps: matched.rateBps,
      involuntary: false,
    ),
  );
}
