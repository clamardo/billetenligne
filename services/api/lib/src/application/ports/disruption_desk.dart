import 'package:bel_domain/bel_domain.dart';

/// A disruption as it stands, for whoever is reading.
final class DisruptionRecord {
  const DisruptionRecord({
    required this.id,
    required this.departureId,
    required this.disruption,
    required this.marksInvoluntary,
    required this.bookingsAffected,
    this.resolvedAt,
  });

  final String id;
  final String departureId;

  /// The declaration itself, rehydrated into the domain type — so the console,
  /// the traveller app and the message composer all read it through the same
  /// object that validated it (ADR-0004).
  final Disruption disruption;

  /// Frozen at declaration. Deliberately not recomputed from [disruption]:
  /// the threshold that decides it can change, and what a passenger was
  /// promised cannot.
  final bool marksInvoluntary;

  final int bookingsAffected;
  final DateTime? resolvedAt;

  bool get isOpen => resolvedAt == null;
}

/// Why a declaration was refused.
///
/// A sealed class rather than an enum for one reason: the third case carries
/// the domain's own refusal. Validating a declaration needs the departure's
/// scheduled time, which only the store has read — so the check happens here
/// and the answer has to arrive with the same code the console would have
/// produced locally, not flattened into "bad request".
sealed class DeclarationRefusal {
  const DeclarationRefusal();
  String get code;
}

/// No such departure under this operator. The same answer for "does not
/// exist" and "belongs to somebody else", because the second must not be
/// distinguishable from the first.
final class UnknownDeparture extends DeclarationRefusal {
  const UnknownDeparture();
  @override
  String get code => 'disruption.unknown_departure';
}

/// It already arrived. A breakdown declared on a coach that finished its
/// journey yesterday is a mistyped identifier, and applying it would send
/// forty-two people a message about a trip they completed.
final class DepartureAlreadyArrived extends DeclarationRefusal {
  const DepartureAlreadyArrived();
  @override
  String get code => 'disruption.already_arrived';
}

/// The domain refused it — a delay with no new time, a revised time that is
/// not later, an estimate already in the past.
final class DeclarationInvalid extends DeclarationRefusal {
  const DeclarationInvalid(this.failure);
  final DisruptionRefusal failure;
  @override
  String get code => failure.code;
}

/// The dispatcher's side of `08-disruption.md`.
///
/// One method that matters, and it does five things in one transaction
/// because any prefix of them committing alone is a nameable failure:
///
///   * the disruption is recorded — evidence, and immutable once written;
///   * any open disruption on the same departure is superseded, so "what is
///     happening to my coach right now?" keeps exactly one answer;
///   * the departure's status follows, when the kind implies one;
///   * every confirmed booking is marked `involuntary_change` when the
///     declaration entitles them to it — the flag that permanently exempts
///     them from fees and fare differences (ADR-0016);
///   * one outbox row per booking, so passengers are told by the drain rather
///     than by a send inline with the dispatcher's request (ADR-0019 rule 1).
///
/// The one that must never commit alone is the fourth: bookings marked
/// involuntary with no disruption row to justify it is a refund entitlement
/// nobody can account for.
abstract interface class DisruptionDesk {
  Future<Result<DisruptionRecord, DeclarationRefusal>> declare({
    required String operatorId,
    required String departureId,
    required DisruptionKind kind,
    required DisruptionCause cause,
    required String actorUserId,
    required DateTime now,
    String? note,
    String? location,
    DateTime? revisedDepartsAt,
    DateTime? estimatedResolution,
  });

  /// What is open on this operator's departures, keyed by departure id.
  ///
  /// One query for a whole day's board rather than one per row: the
  /// dispatcher's first screen lists every departure, and a per-row lookup
  /// there is thirty round trips on a connection that has none to spare.
  Future<Map<String, DisruptionRecord>> openFor({
    required String operatorId,
    required DateTime from,
    required DateTime to,
  });
}
