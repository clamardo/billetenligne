import 'package:bel_domain/bel_domain.dart';

/// One departure the traveller could move to, priced (`01-feature-spec.md`
/// §8.1).
///
/// The row carries its own answer. §8.1's mock shows the fare difference and
/// the fee **on every result row before selection**, which is the whole
/// design: somebody scanning a list is comparing prices, and a screen that
/// only prices the row you tapped makes them tap five times to compare.
final class ChangeOption {
  const ChangeOption({
    required this.departureId,
    required this.departsAt,
    required this.arrivesAt,
    required this.fare,
    required this.seatsAvailable,
    this.quote,
    this.refusal,
  });

  final String departureId;
  final DateTime departsAt;

  /// On every row, because the question being asked is when they arrive.
  final DateTime arrivesAt;

  final Money fare;
  final int seatsAvailable;

  /// Null when [refusal] is set.
  final ChangeQuote? quote;

  /// Why this row cannot be taken — it does not fit the party, it leaves too
  /// soon. Shown rather than hidden: a departure missing from a list is a
  /// departure somebody phones to ask about.
  final ChangeRefusal? refusal;
}

/// The whole change screen, in one answer.
final class ChangeOptions {
  const ChangeOptions({
    required this.bookingRef,
    required this.originCity,
    required this.destinationCity,
    required this.seatsNeeded,
    required this.currentDepartureId,
    required this.currentDepartsAt,
    required this.paidFare,
    required this.policy,
    required this.options,
    this.involuntary = false,
    this.refusal,
  });

  final String bookingRef;
  final String originCity;
  final String destinationCity;

  /// The party. Three people who booked together move together or not at all,
  /// which is the same rule the rebooking wave follows.
  final int seatsNeeded;

  final String currentDepartureId;
  final DateTime currentDepartsAt;

  /// What they paid, per seat. Every difference on the screen is against it.
  final Money paidFare;

  final ChangePolicy policy;
  final List<ChangeOption> options;

  /// True when the operator caused a change to this booking already. Every
  /// row is then free, whatever the window says (ADR-0016).
  final bool involuntary;

  /// Set when no change is possible at all — the coach has left, or it is
  /// inside the cutoff. The screen renders the reason and no rows.
  final ChangeRefusal? refusal;
}

/// What happened when they tapped.
final class ChangeApplied {
  const ChangeApplied({
    required this.bookingRef,
    required this.departureId,
    required this.departsAt,
    required this.seatLabels,
  });

  final String bookingRef;
  final String departureId;
  final DateTime departsAt;
  final List<String> seatLabels;
}

/// The traveller moving themselves to another departure (§8.1).
///
/// Distinct from `PassengerChoices`, which is the same movement offered after
/// a breakdown: that one is an entitlement the operator opened, priced at
/// nothing and bounded by a deadline. This one is a purchase decision the
/// traveller makes unprompted, priced by the terms they bought under, and
/// available on any day nothing has gone wrong.
abstract interface class RescheduleDesk {
  /// The screen. Null when the reference is not this traveller's — which is
  /// what a reference that does not exist looks like too.
  Future<ChangeOptions?> options({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });

  /// Moves them. Null when the reference is not theirs, so the two verbs
  /// cannot be told apart by somebody guessing references.
  ///
  /// The seats on the new coach are taken **before** the old ones are
  /// released, and the decision is re-taken under the lock: the row was
  /// priced before it, and the coach can fill in between.
  Future<({ChangeApplied? applied, ChangeRefusal? refusal})?> change({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  });
}

/// The null object, for a server with no database behind it.
final class NoReschedules implements RescheduleDesk {
  const NoReschedules();

  @override
  Future<ChangeOptions?> options({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => null;

  @override
  Future<({ChangeApplied? applied, ChangeRefusal? refusal})?> change({
    required String bookingRef,
    required String userId,
    required String toDepartureId,
    required DateTime now,
  }) async => null;
}
