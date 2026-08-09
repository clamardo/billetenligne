import '../money/money.dart';
import '../shared/failure.dart';
import '../shared/result.dart';

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
