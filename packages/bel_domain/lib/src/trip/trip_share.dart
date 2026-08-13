library;

import '../shared/result.dart';

/// Sharing a trip with somebody who is not a customer (ADR-0014 §2).
///
/// The use case is specific and very common here: a relative travelling the
/// 512 km of the RN1 between Brazzaville and Pointe-Noire, and somebody at the
/// other end deciding when to leave for the station. Today that is solved with
/// phone credit and repeated calls.
///
/// Two rules the whole design rests on, and they are the reason this lives in
/// the domain rather than in a handler:
///
///   * **We follow a coach, never a person.** Everything a follower is shown
///     is a fact about a departure. That is both the ethical line and the
///     thing that makes it acceptable to the conductor whose device would
///     otherwise be reporting somebody's position.
///   * **Never draw a confident dot from a guess.** Progress has three tiers
///     with very different confidence, and the tier is stated on the page
///     rather than smoothed away. A trustworthy "passé Dolisie à 10:42" beats
///     a clever estimate that is wrong.

/// How much we actually know about where the coach is (ADR-0014 §1).
enum TrackingTier {
  /// The conductor's device reported a position. Shown with the age of the
  /// reading, because a live dot that is forty minutes old is a lie.
  gps,

  /// Somebody confirmed passage at a waypoint — Dolisie, Nkayi, Madingou.
  /// One tap, and worth more than an estimate.
  checkpoint,

  /// Nothing has been reported. The timetable is all we have, and the page
  /// says so in as many words.
  schedule,
}

/// A share link's life.
///
/// **Arrival plus six hours.** Long enough that a coach running four hours
/// late is still followable — which is exactly when somebody is watching —
/// and short enough that a link forwarded through three WhatsApp groups stops
/// working before it becomes a permanent public record of somebody's travel.
DateTime shareExpiry(DateTime arrivesAt) =>
    arrivesAt.add(const Duration(hours: 6));

/// Why a trip could not be shared, or a link could not be opened.
sealed class ShareRefusal {
  const ShareRefusal();
  String get code;
}

/// The booking is not paid for. There is no trip to follow yet, and a link
/// that resolved to a reservation somebody may never pay for would be a link
/// that quietly stops working.
final class NothingToShare extends ShareRefusal {
  const NothingToShare();
  @override
  String get code => 'share.not_confirmed';
}

/// No such link, or a link whose booking is gone. The same answer as a
/// revoked one on purpose — see [ShareRevoked].
final class UnknownShare extends ShareRefusal {
  const UnknownShare();
  @override
  String get code => 'share.unknown';
}

/// Past `arrival + 6 h`.
final class ShareExpired extends ShareRefusal {
  const ShareExpired();
  @override
  String get code => 'share.expired';
}

/// The traveller revoked it.
///
/// Answered to the follower as [UnknownShare], not as this: "this link was
/// revoked" tells whoever holds it that it was once real and that somebody
/// took it away from them, which is a conversation the traveller did not ask
/// to start. This code exists for the traveller's own screen.
final class ShareRevoked extends ShareRefusal {
  const ShareRevoked();
  @override
  String get code => 'share.revoked';
}

/// Where the coach is, as far as anybody honestly knows.
final class TripProgress {
  const TripProgress({
    required this.tier,
    required this.fraction,
    this.reportedAt,
    this.checkpointName,
  });

  final TrackingTier tier;

  /// 0 at the origin, 1 at the destination. Clamped, because a coach running
  /// three hours late must not render as 140% of the way there.
  final double fraction;

  /// When the underlying fact was true — the GPS fix, or the checkpoint tap.
  /// Null on [TrackingTier.schedule], which has no observation behind it.
  final DateTime? reportedAt;

  final String? checkpointName;

  bool get isEstimate => tier == TrackingTier.schedule;
}

/// The schedule tier: what the timetable implies and nothing more.
///
/// Deliberately linear. Interpolating against terrain, traffic or the usual
/// stop at Dolisie would produce a number that looks more precise and is not
/// more true, and ADR-0014 closes with the instruction to resist exactly that.
TripProgress scheduledProgress({
  required DateTime now,
  required DateTime departsAt,
  required DateTime arrivesAt,
}) {
  final total = arrivesAt.difference(departsAt).inSeconds;
  if (total <= 0) {
    return TripProgress(
      tier: TrackingTier.schedule,
      fraction: now.isBefore(departsAt) ? 0 : 1,
    );
  }

  final elapsed = now.difference(departsAt).inSeconds;
  final raw = elapsed / total;

  return TripProgress(
    tier: TrackingTier.schedule,
    fraction: raw < 0
        ? 0
        : raw > 1
        ? 1
        : raw,
  );
}

/// A checkpoint the coach has been confirmed past, placed along the route.
final class Checkpoint {
  const Checkpoint({
    required this.name,
    required this.fraction,
    required this.passedAt,
  });

  /// A waypoint placed by the timetable rather than by a number somebody
  /// typed: [offsetMinutes] into a run of [durationMinutes].
  ///
  /// The route already knows how far along Dolisie is, because a stop there
  /// has to be sold with a departure time. Deriving the fraction from that
  /// beats a second column an operator would have to maintain and would get
  /// subtly wrong the first time a road is rerouted.
  ///
  /// Clamped, and 0 for a route with no duration: a stop whose offset is
  /// longer than the whole run is a timetable somebody mistyped, and the bar
  /// must not render at 130% while they fix it.
  factory Checkpoint.onRoad({
    required String name,
    required int offsetMinutes,
    required int durationMinutes,
    required DateTime passedAt,
  }) {
    final raw = durationMinutes <= 0 ? 0.0 : offsetMinutes / durationMinutes;
    return Checkpoint(
      name: name,
      fraction: raw < 0
          ? 0
          : raw > 1
          ? 1
          : raw,
      passedAt: passedAt,
    );
  }

  final String name;

  /// Where this waypoint sits on the run, 0 to 1. Dolisie is roughly two
  /// thirds of the way from Brazzaville to Pointe-Noire.
  final double fraction;

  final DateTime passedAt;
}

/// Progress from the last confirmed checkpoint, carried forward by the clock.
///
/// The confirmed part is a fact and the part after it is arithmetic, so the
/// tier stays [TrackingTier.checkpoint] and the page shows the fact — "passé
/// Dolisie à 10:42" — rather than the arithmetic. Somebody deciding when to
/// leave for the station acts on the checkpoint, not on the bar.
TripProgress checkpointProgress({
  required DateTime now,
  required DateTime departsAt,
  required DateTime arrivesAt,
  required Checkpoint last,
}) {
  final schedule = scheduledProgress(
    now: now,
    departsAt: departsAt,
    arrivesAt: arrivesAt,
  );

  // Never behind the checkpoint: the coach is confirmed past it, whatever the
  // timetable thinks. A bar that walked backwards after a conductor's tap
  // would make the tap look like a mistake.
  final fraction = schedule.fraction < last.fraction
      ? last.fraction
      : schedule.fraction;

  return TripProgress(
    tier: TrackingTier.checkpoint,
    fraction: fraction,
    reportedAt: last.passedAt,
    checkpointName: last.name,
  );
}

/// Whether a link may still be opened.
///
/// Revocation and expiry are both refusals here and the *same* refusal to the
/// follower; the distinction is kept so the traveller's own screen can say
/// which one happened.
Result<void, ShareRefusal> openable({
  required DateTime now,
  required DateTime expiresAt,
  DateTime? revokedAt,
}) {
  if (revokedAt != null) return const Err(ShareRevoked());
  if (!now.isBefore(expiresAt)) return const Err(ShareExpired());
  return const Ok(null);
}
