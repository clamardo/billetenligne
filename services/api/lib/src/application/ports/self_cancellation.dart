import 'package:bel_domain/bel_domain.dart';

/// What cancelling one booking would do, as the server computes it (§8.2).
///
/// Assembled in one read, like the choice screen: somebody deciding whether
/// to cancel is deciding about money, and three round trips to build the
/// sentence is three chances to show them half of it.
final class CancellationOffer {
  const CancellationOffer({
    required this.bookingRef,
    required this.departsAt,
    required this.originCity,
    required this.destinationCity,
    required this.seatCount,
    required this.fare,
    required this.serviceFee,
    this.kind,
    this.quote,
    this.givesNothingBack = false,
    this.policy,
    this.policyName,
    this.refusal,
  });

  final String bookingRef;
  final DateTime departsAt;
  final String originCity;
  final String destinationCity;
  final int seatCount;
  final Money fare;
  final Money serviceFee;

  /// Null when [refusal] is set.
  final CancellationKind? kind;

  /// Null on a release — nothing was paid, so there is nothing to quote.
  final RefundQuote? quote;

  /// True when the bands have all elapsed. The cancellation is still allowed;
  /// what changes is the sentence above the button.
  final bool givesNothingBack;

  /// The version the booking was **sold under**, never the operator's current
  /// default (ADR-0015 rule 1).
  final RefundPolicy? policy;
  final String? policyName;

  final CancellationRefusal? refusal;
}

/// What actually happened.
final class CancellationDone {
  const CancellationDone({
    required this.bookingRef,
    required this.kind,
    this.refunded,
    this.claimCode,
    this.claimExpiresAt,
    this.processingWindow,
  });

  final String bookingRef;
  final CancellationKind kind;
  final Money? refunded;
  final String? claimCode;
  final DateTime? claimExpiresAt;
  final Duration? processingWindow;
}

/// The traveller cancelling their own booking (`01-feature-spec.md` §8.2).
///
/// Separate from `OperatorConsole.refundBooking` for the same reason
/// `PassengerChoices` is separate from `DisruptionDesk`: the actor is
/// different in the way that decides everything. A vendor refunds *somebody
/// else's* booking under a capability and writes a reason for the audit; a
/// traveller cancels *their own*, holds no capability at all, and the only
/// thing standing between them and every other booking in the country is that
/// the first read runs as themselves.
abstract interface class SelfCancellation {
  /// The sentence before the button. Null when the reference is not this
  /// traveller's — which is also what a reference that does not exist looks
  /// like, deliberately.
  Future<CancellationOffer?> offer({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });

  /// Does it.
  ///
  /// Null — not a refusal — when the reference is not this traveller's, so the
  /// answer matches [offer]'s exactly. A POST that said "nothing to cancel"
  /// where the GET said "no such booking" would be a difference somebody
  /// could measure, and a booking reference is six characters.
  ///
  /// A refusal is the world having moved between the screen and the tap: the
  /// coach left, a counter refunded it first, a payment landed.
  Future<({CancellationDone? done, CancellationRefusal? refusal})?> cancel({
    required String bookingRef,
    required String userId,
    required DateTime now,
  });
}

/// The null object, for a server with no database behind it.
final class NoSelfCancellation implements SelfCancellation {
  const NoSelfCancellation();

  @override
  Future<CancellationOffer?> offer({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => null;

  @override
  Future<({CancellationDone? done, CancellationRefusal? refusal})?> cancel({
    required String bookingRef,
    required String userId,
    required DateTime now,
  }) async => null;
}
