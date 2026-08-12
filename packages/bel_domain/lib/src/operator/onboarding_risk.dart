import 'operator_application.dart';

/// What an external screen said about the owner (`03-operator-lifecycle.md`
/// §2.3, "Sanctions / PEP screen").
///
/// Three values, not two, and the third is the important one. **`notRun` is
/// not `clear`.** No screening vendor is wired, so that is what the adapter
/// actually returns today, and it is what keeps automatic approval switched
/// off by *data* rather than by dead code — the same shape as a payment rail
/// that ships without credentials. The day a vendor exists, one adapter
/// starts answering `clear` and this path comes alive with nothing else
/// changed.
enum ScreeningOutcome { clear, hit, notRun }

/// How much of a bet an applicant is.
///
/// Not a score out of five. A score invites argument about the threshold and
/// hides which check failed; three bands with named reasons say what would
/// have to change.
enum RiskBand {
  /// Small, complete, and screened clear. Approved without a human
  /// (`09-roadmap.md`, Phase 4).
  low,

  /// The ordinary case: a reviewer looks at it. Not a rejection and not a
  /// suspicion — most operators are simply bigger than the automatic bar.
  standard,

  /// Something a person must see before anybody sells a ticket: a screening
  /// hit, a duplicate of a company we already know, or a previous
  /// offboarding. **Never auto-approvable, at any size.**
  elevated,
}

/// Why an application is not in the band below it.
///
/// Codes, never sentences (ADR-0008). The reviewer's screen renders
/// `application.risk.<code>` and the applicant is never shown these at all —
/// telling somebody they failed a sanctions screen is how a screen becomes a
/// tool for testing which alias passes.
abstract final class RiskReason {
  static const incomplete = 'incomplete';
  static const fleetTooLarge = 'fleet_too_large';
  static const departuresTooMany = 'departures_too_many';
  static const settlementNameMismatch = 'settlement_name_mismatch';

  /// A licence or an insurance certificate that is valid, but not for long.
  /// Auto-approving a company whose insurance lapses in three weeks means
  /// blocking them in three weeks, which is a worse first month than a review.
  static const licenceRunway = 'licence_runway';
  static const insuranceRunway = 'insurance_runway';

  static const screeningNotRun = 'screening_not_run';
  static const screeningHit = 'screening_hit';
  static const duplicateOperator = 'duplicate_operator';
  static const priorOffboarding = 'prior_offboarding';
}

/// Where the automatic bar sits.
///
/// A parameter rather than a constant because the honest answer to "how many
/// coaches is small" is *we will find out*, and moving it should be a
/// configuration change rather than a release.
final class RiskLimits {
  const RiskLimits({
    this.fleetSize = 5,
    this.dailyDepartures = 6,
    this.documentRunway = const Duration(days: 90),
  });

  /// Exposure, not trust. A three-coach company that turns out to be a
  /// disaster strands a bus-load; a forty-coach one strands a season.
  final int fleetSize;
  final int dailyDepartures;

  /// How long a licence and an insurance certificate must still have to run.
  /// Ninety days is a full quarter, and it is also where the expiry ladder's
  /// first reminder has not yet fired (§3.3) — so an automatically approved
  /// operator does not meet their first enforcement in week two.
  final Duration documentRunway;
}

/// The decision, and everything it rests on.
///
/// **Pure.** The two facts the domain cannot know — whether a screen ran, and
/// whether this company already exists here — are arguments. Everything else
/// is read off the application the applicant filled in, which is the whole
/// reason this can be tested without a database or a vendor.
final class OnboardingRisk {
  const OnboardingRisk._(this.band, this.reasons);

  final RiskBand band;

  /// Sorted and de-duplicated, so two runs over one application produce the
  /// same row and a reviewer's screen does not reshuffle on refresh.
  final List<String> reasons;

  /// The one question the pass asks. `low` and nothing else — an elevated
  /// application with a small fleet is still elevated.
  bool get autoApprovable => band == RiskBand.low;

  static OnboardingRisk of(
    ApplicationFacts facts, {
    required ScreeningOutcome screening,
    required DateTime now,
    bool duplicate = false,
    bool priorOffboarding = false,
    RiskLimits limits = const RiskLimits(),
  }) {
    // Anything here means a person looks, whatever else is true. Kept apart
    // from the list below rather than weighted into it, because a bet nobody
    // should take is not the far end of a scale.
    final stopping = <String>{
      if (screening == ScreeningOutcome.hit) RiskReason.screeningHit,
      if (duplicate) RiskReason.duplicateOperator,
      if (priorOffboarding) RiskReason.priorOffboarding,
    };

    final ordinary = <String>{
      if (!facts.isSubmittable(asOf: now)) RiskReason.incomplete,
      if ((facts.fleetSize ?? 0) > limits.fleetSize) RiskReason.fleetTooLarge,
      if ((facts.dailyDepartures ?? 0) > limits.dailyDepartures)
        RiskReason.departuresTooMany,
      if (!facts.settlementNameMatchesLegalName)
        RiskReason.settlementNameMismatch,
      if (!_hasRunway(facts.transportLicenceExpires, now, limits))
        RiskReason.licenceRunway,
      if (!_hasRunway(facts.fleetInsuranceExpires, now, limits))
        RiskReason.insuranceRunway,
      if (screening == ScreeningOutcome.notRun) RiskReason.screeningNotRun,
    };

    if (stopping.isNotEmpty) {
      return OnboardingRisk._(
        RiskBand.elevated,
        _sorted({...stopping, ...ordinary}),
      );
    }
    if (ordinary.isNotEmpty) {
      return OnboardingRisk._(RiskBand.standard, _sorted(ordinary));
    }
    return const OnboardingRisk._(RiskBand.low, []);
  }

  static bool _hasRunway(DateTime? expires, DateTime now, RiskLimits limits) =>
      expires != null && expires.isAfter(now.add(limits.documentRunway));

  static List<String> _sorted(Set<String> codes) =>
      List.unmodifiable(codes.toList()..sort());
}
