import 'package:bel_domain/bel_domain.dart';

/// The choice screen, as the server computes it (`08-disruption.md` §3.2).
///
/// Everything one screen needs in one answer. A passenger opening this is
/// standing at a roadside on a connection that drops; three round trips to
/// assemble it is three chances to show them nothing.
final class TravelChoices {
  const TravelChoices({
    required this.bookingRef,
    required this.options,
    required this.deadline,
    required this.seatsNeeded,
    required this.originCity,
    required this.destinationCity,
    required this.disruptionKind,
    required this.reasonKey,
    this.note,
    this.open = true,
  });

  final String bookingRef;

  /// In display order: what they already have, then the alternatives, then
  /// the refund — which is always last and always present (§3.2).
  final List<TravelChoice> options;

  /// When the screen closes, and after which the assigned option stands.
  final DateTime deadline;

  /// The party. Three people who booked together move together or not at all.
  final int seatsNeeded;

  final String originCity;
  final String destinationCity;

  final String disruptionKind;

  /// The sentence the passenger already received by SMS, so the screen and
  /// the message say the same thing.
  final String reasonKey;

  final String? note;

  /// False once the deadline has passed or the disruption is resolved. The
  /// screen still renders — with what they are on and no buttons — because a
  /// passenger who follows a link and finds nothing assumes the worst.
  final bool open;

  /// What happens to somebody who never answers.
  TravelChoice? get fallback => options.where((o) => o.assigned).firstOrNull;
}

/// What actually happened when they tapped.
final class ChoiceApplied {
  const ChoiceApplied({
    required this.bookingRef,
    required this.kind,
    this.departureId,
    this.departsAt,
    this.seatLabels = const [],
    this.refunded,
    this.claimCode,
  });

  final String bookingRef;
  final TravelChoiceKind kind;

  final String? departureId;
  final DateTime? departsAt;
  final List<String> seatLabels;

  /// On a refund: what comes back, and the code that collects it.
  final Money? refunded;
  final String? claimCode;
}

/// The passenger deciding for themselves (`08-disruption.md` §3.2).
///
/// Separate from `DisruptionDesk` because the actor is different in the way
/// that matters: the desk is an operator acting on a coachload, this is one
/// traveller acting on their own booking. They share the domain rules and
/// nothing else — including, deliberately, the error vocabulary, since a
/// passenger must never read a sentence written for a dispatcher.
abstract interface class PassengerChoices {
  /// What this passenger may do about their disrupted journey.
  ///
  /// Null when the reference is not theirs — which is also what a reference
  /// that does not exist looks like, deliberately: the alternative is an
  /// endpoint that tells a stranger which references are real.
  Future<TravelChoices?> optionsFor({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });

  /// Take one.
  ///
  /// **The seats are taken before the old ones are released** (§2.4), like
  /// every other movement in this system, and for the same reason: the
  /// released seat goes back into the pool for the other passengers on the
  /// broken coach, and a gap between the two is a passenger with no seat
  /// anywhere.
  Future<({ChoiceApplied? applied, ChoiceRefusal? refusal})> choose({
    required String bookingRef,
    required String userId,
    required String optionId,
    required DateTime now,
  });
}

/// What the fakes composition answers with: a journey nothing is happening
/// to. There is no useful way to fake a disruption.
final class NoChoices implements PassengerChoices {
  const NoChoices();

  @override
  Future<TravelChoices?> optionsFor({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => null;

  @override
  Future<({ChoiceApplied? applied, ChoiceRefusal? refusal})> choose({
    required String bookingRef,
    required String userId,
    required String optionId,
    required DateTime now,
  }) async => (applied: null, refusal: const NothingDisrupted());
}
