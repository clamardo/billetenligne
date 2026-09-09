import 'package:bel_domain/bel_domain.dart';

/// A link the traveller holds.
final class TripShare {
  const TripShare({
    required this.expiresAt,
    required this.opens,
    required this.revoked,
    this.token,
  });

  /// The plaintext, present **only** on the response that mints it. Stored as
  /// a hash, so there is nowhere else it could come back from.
  final String? token;

  final DateTime expiresAt;
  final int opens;
  final bool revoked;
}

/// What a follower sees, assembled from a coach and nothing else.
final class FollowedTrip {
  const FollowedTrip({
    required this.operatorName,
    required this.routeCode,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.status,
    required this.progress,
    required this.expiresAt,
    this.disruptionKind,
    this.disruptionCause,
    this.disruptionNote,
    this.revisedDepartsAt,
  });

  final String operatorName;
  final String routeCode;
  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final String status;
  final TripProgress progress;
  final DateTime expiresAt;

  final String? disruptionKind;
  final String? disruptionCause;
  final String? disruptionNote;
  final DateTime? revisedDepartsAt;
}

/// One place on the road, as the passenger's ticket lists it.
final class JourneyStop {
  const JourneyStop({
    required this.name,
    required this.offsetMinutes,
    this.passedAt,
  });

  /// The station if the stop names one, the city otherwise — the name a
  /// person on the coach would use for where they just were.
  final String name;

  /// Minutes into the run. What puts the list in road order without the
  /// screen having to know anything about roads.
  final int offsetMinutes;

  /// When the conductor confirmed the coach past it, on the conductor's own
  /// clock. Null for everywhere still ahead.
  final DateTime? passedAt;

  bool get isBehind => passedAt != null;
}

/// The journey a ticket holder is on (J6).
///
/// The same facts a follower gets from [FollowedTrip], read through the
/// booking instead of through a token, plus the stop list — a passenger on
/// the coach is looking at the road they are on, not at a bar.
///
/// Deliberately **not** the operator's name, the route code or the cities:
/// they came with the booking and the screen already has them. Sending them
/// again would be a second copy that can disagree with the first.
final class TripJourney {
  const TripJourney({
    required this.departsAt,
    required this.arrivesAt,
    required this.status,
    required this.progress,
    required this.stops,
    this.revisedDepartsAt,
  });

  final DateTime departsAt;
  final DateTime arrivesAt;

  /// The dispatcher's new time when a delay has been declared. Present
  /// because the progress below is measured from it — an estimate drawn from
  /// a departure that did not happen is worse than no estimate.
  final DateTime? revisedDepartsAt;

  final String status;
  final TripProgress progress;

  /// In the order the road runs, with what is behind marked.
  final List<JourneyStop> stops;
}

/// Sharing a trip, and following one (ADR-0014 §2).
///
/// Two callers with nothing in common: a traveller holding a session, and a
/// stranger holding a link. They are on the same port because they are the two
/// ends of one thing, and keeping them together is what makes it obvious that
/// [follow] must never be able to answer with anything [share] would not have
/// been willing to hand over.
abstract interface class TripSharing {
  /// Mints a link, or returns the live one unchanged.
  ///
  /// Idempotent by design rather than by an idempotency key: sharing twice
  /// must not leave a second live link the traveller cannot see to revoke.
  /// The token comes back **only** the first time.
  Future<Result<TripShare, ShareRefusal>> share({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });

  /// The traveller's own view of their link: how many people opened it, when
  /// it dies. Null when they never shared this booking.
  Future<TripShare?> shareFor({
    required String bookingRef,
    required String userId,
  });

  /// Kills it. Idempotent — revoking twice is not an error, because the
  /// traveller pressing it twice on a bad connection means the same thing
  /// both times.
  Future<Result<void, ShareRefusal>> revoke({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });

  /// The follower's read. Anonymous, and counts the open.
  ///
  /// A revoked link and a token nobody ever issued get the **same** answer:
  /// "this link was revoked" tells whoever holds it that it was once real and
  /// that somebody took it away from them, which is a conversation the
  /// traveller did not ask to start.
  Future<FollowedTrip?> follow({required String token, required DateTime now});

  /// Where the passenger's own coach has got to (J6).
  ///
  /// On this port rather than on one of its own, because it and [follow] are
  /// two doors into the same room. Keeping them side by side is what makes it
  /// obvious that neither may ever be able to answer with something the other
  /// would not — the follower's read has always been the careful one, and a
  /// journey read that grew a passenger list somewhere else in the tree would
  /// be much harder to notice.
  ///
  /// Null for a booking that is not this traveller's, is not paid for, or was
  /// cancelled. Somebody who cancelled last week is not on that coach, and
  /// where it has got to stopped being their business.
  Future<TripJourney?> journey({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });
}

/// The fakes composition, which has no database to share a trip out of.
///
/// Refuses rather than inventing a link: a token that resolves in development
/// and nowhere else is a feature that looks built and is not.
final class NoTripSharing implements TripSharing {
  const NoTripSharing();

  @override
  Future<Result<TripShare, ShareRefusal>> share({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => const Err(UnknownShare());

  @override
  Future<TripShare?> shareFor({
    required String bookingRef,
    required String userId,
  }) async => null;

  @override
  Future<Result<void, ShareRefusal>> revoke({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => const Err(UnknownShare());

  @override
  Future<FollowedTrip?> follow({
    required String token,
    required DateTime now,
  }) async => null;

  @override
  Future<TripJourney?> journey({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => null;
}
