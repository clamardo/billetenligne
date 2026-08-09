import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/seat_inventory.dart';

/// Why a hold could not be created.
///
/// Each one is a distinct thing that happened to a real person, and each gets
/// its own sentence in the app. Collapsing them into "seat unavailable" is how
/// a traveller ends up retrying a request that can never succeed.
sealed class HoldSeatsFailure extends DomainFailure {
  const HoldSeatsFailure();
}

final class NoSeatsRequested extends HoldSeatsFailure {
  const NoSeatsRequested();
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => const {'field': 'seatLabels'};
}

/// Six is not a technical limit. It is the largest group an agent will sell
/// over a counter without checking with someone, and holding twenty seats on
/// a fifty-seat coach with no intention of paying is the cheapest denial of
/// service there is.
final class TooManySeats extends HoldSeatsFailure {
  const TooManySeats(this.requested, this.max);
  final int requested;
  final int max;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'requested': requested, 'max': max};
}

final class DuplicateSeatRequested extends HoldSeatsFailure {
  const DuplicateSeatRequested(this.seatLabel);
  final String seatLabel;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'seat': seatLabel};
}

/// The key already belongs to somebody else's hold. A 409, and honest about
/// which of the two things went wrong — the seat was never the problem.
final class HoldKeyBelongsToAnother extends HoldSeatsFailure {
  const HoldKeyBelongsToAnother();
  @override
  String get code => ErrorCode.idempotencyKeyReused;
}

final class SeatsAlreadyTaken extends HoldSeatsFailure {
  const SeatsAlreadyTaken(this.seatLabels);
  final List<String> seatLabels;
  @override
  String get code => ErrorCode.seatUnavailable;
  @override
  Map<String, Object?> get params => {'seats': seatLabels.join(', ')};
}

final class SeatsNotOnDeparture extends HoldSeatsFailure {
  const SeatsNotOnDeparture(this.seatLabels);
  final List<String> seatLabels;
  @override
  String get code => ErrorCode.notFound;
  @override
  Map<String, Object?> get params => {'seats': seatLabels.join(', ')};
}

final class DepartureUnavailable extends HoldSeatsFailure {
  const DepartureUnavailable(this.reason);
  final String reason;

  @override
  String get code => switch (reason) {
    DepartureNotSellable.missing => ErrorCode.notFound,
    DepartureNotSellable.cancelled => ErrorCode.departureCancelled,
    _ => ErrorCode.departureClosed,
  };

  @override
  Map<String, Object?> get params => {'reason': reason};
}

/// Claim seats for a traveller.
///
/// The whole booking funnel narrows to this one call. Everything before it is
/// browsing; everything after it is money. Three things have to be true at
/// once and this class is where they are made true:
///
///   * **Exactly one traveller gets a given seat.** Enforced by the adapter's
///     row lock, not by anything here — application code cannot win a race.
///   * **The price comes from the seat row.** Never from the client, never
///     recomputed from the departure. A seat can carry its own fare.
///   * **A retry returns the same hold.** The idempotency key is the identity
///     of the attempt, and the database's unique index is what makes that
///     true even when the middleware's store and the hold row disagree after
///     a crash.
final class HoldSeats {
  /// Takes no [Clock], deliberately. Every instant that matters here — when
  /// the hold starts, when it expires — is decided by the database, because
  /// three API instances with three slightly different clocks must not
  /// disagree about who owns seat 12A.
  const HoldSeats({
    required SeatInventory inventory,
    this.policy = HoldPolicy.standard,
    this.market = Market.current,
    this.maxSeatsPerHold = 6,
  }) : _inventory = inventory;

  final SeatInventory _inventory;
  final HoldPolicy policy;
  final Market market;
  final int maxSeatsPerHold;

  Future<Result<HoldDto, HoldSeatsFailure>> call({
    required String departureId,
    required List<String> seatLabels,
    required String userId,
    required String idempotencyKey,
    String channel = 'app',
  }) async {
    final requested = [for (final s in seatLabels) s.trim().toUpperCase()];

    if (requested.isEmpty || requested.any((s) => s.isEmpty)) {
      return const Err(NoSeatsRequested());
    }
    if (requested.length > maxSeatsPerHold) {
      return Err(TooManySeats(requested.length, maxSeatsPerHold));
    }

    final seen = <String>{};
    for (final label in requested) {
      if (!seen.add(label)) return Err(DuplicateSeatRequested(label));
    }

    // Sorted, always. Two travellers racing for the same pair of seats must
    // take the row locks in the same order or they deadlock, and the loser
    // gets a Postgres error where they expected a seat map.
    final ordered = seen.toList()..sort();

    final outcome = await _inventory.claim(
      SeatClaim(
        departureId: departureId,
        seatLabels: ordered,
        userId: userId,
        ttl: policy.ttl,
        idempotencyKey: idempotencyKey,
        channel: channel,
      ),
    );

    return switch (outcome) {
      SeatsClaimed(:final holdId, :final fare, :final expiresAt) => Ok(
        _toDto(
          holdId: holdId,
          departureId: departureId,
          seatLabels: ordered,
          fare: fare,
          // The expiry the DATABASE computed, not one this process guessed.
          // The countdown the traveller watches has to be the countdown the
          // row actually has, or it lies at exactly the wrong moment.
          expiresAt: expiresAt,
        ),
      ),
      SeatsTaken(:final seatLabels) => Err(SeatsAlreadyTaken(seatLabels)),
      IdempotencyKeyTaken() => const Err(HoldKeyBelongsToAnother()),
      SeatsUnknown(:final seatLabels) => Err(SeatsNotOnDeparture(seatLabels)),
      DepartureNotSellable(:final reason) => Err(DepartureUnavailable(reason)),
    };
  }

  HoldDto _toDto({
    required String holdId,
    required String departureId,
    required List<String> seatLabels,
    required Money fare,
    required DateTime expiresAt,
  }) {
    // Once per booking, not once per seat. A family of four is one
    // transaction on one wallet and paying the fee four times would be
    // indefensible when the receipt is read aloud at the counter.
    final serviceFee = market.serviceFee;

    return HoldDto(
      id: holdId,
      departureId: departureId,
      seatLabels: seatLabels,
      expiresAt: expiresAt,
      fare: fare,
      serviceFee: serviceFee,
      total: fare + serviceFee,
      state: 'active',
    );
  }
}
