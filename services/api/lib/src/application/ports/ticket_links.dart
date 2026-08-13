import 'package:bel_domain/bel_domain.dart';

/// Why a link was not sent.
sealed class LinkRefusal extends DomainFailure {
  const LinkRefusal();
}

/// No booking of this operator's with that reference.
final class UnknownBooking extends LinkRefusal {
  const UnknownBooking();
  @override
  String get code => 'ticketLink.unknown_booking';
}

/// A reservation nobody has paid for has no ticket to send. Sending a link to
/// one would produce a page with no QR on it, which reads as our failure
/// rather than as an unpaid booking.
final class NothingToSend extends LinkRefusal {
  const NothingToSend();
  @override
  String get code => 'ticketLink.nothing_to_send';
}

/// The market cannot send on that channel today — SMS with no sender number
/// is the live example. Refused where the vendor is standing, rather than
/// swallowed into a queue that never delivers.
final class ChannelUnavailable extends LinkRefusal {
  const ChannelUnavailable();
  @override
  String get code => 'ticketLink.channel_unavailable';
}

/// Nowhere to send it: no address typed and none on the account.
final class NoDestination extends LinkRefusal {
  const NoDestination();
  @override
  String get code => 'ticketLink.no_destination';
}

/// A send that has been queued. Deliberately **not** the link.
///
/// The vendor is told where it is going, not what was minted — the token does
/// not exist yet, and when it does it will exist in one message and one hash.
/// A URL on the counter screen would be a ticket anybody behind the customer
/// can photograph.
final class QueuedTicketLink {
  const QueuedTicketLink({required this.channel, required this.sentTo});

  final String channel;

  /// As it will be sent, so the vendor can read it back to the customer and
  /// catch the typo while they are still standing there.
  final String sentTo;
}

/// Where a link was delivered, and what it points at.
final class LinkDestination {
  const LinkDestination({
    required this.bookingId,
    required this.channel,
    required this.sentTo,
  });

  final String bookingId;
  final String channel;
  final String sentTo;
}

/// One seat on a linked ticket.
final class LinkedSeat {
  const LinkedSeat({
    required this.seatLabel,
    required this.passengerName,
    required this.payload,
    this.voided = false,
  });

  final String seatLabel;
  final String passengerName;

  /// A seat that was refunded or moved. **Kept and marked, never dropped** —
  /// a page that quietly shows two seats where the customer bought three is a
  /// person counting their family at a coach door wondering what happened.
  final bool voided;

  /// The signed QR string (ADR-0007). Static — it cannot rotate on a page or
  /// in an inbox, which is written down in ADR-0026 rather than glossed: the
  /// control at the door is one scan per seat, not freshness.
  final String payload;
}

/// What the holder of a link is shown.
final class LinkedTicket {
  const LinkedTicket({
    required this.bookingRef,
    required this.state,
    required this.operatorName,
    required this.operatorCode,
    required this.routeCode,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.status,
    required this.stationName,
    required this.stationNotes,
    required this.seats,
    required this.channel,
    required this.expiresAt,
  });

  final String bookingRef;
  final String state;
  final String operatorName;
  final String operatorCode;
  final String routeCode;

  /// The journey **this booking** bought, which on a road with priced legs is
  /// not the road the coach runs (ADR-0025).
  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final String status;

  /// The yard they board at, and the company's own directions to it, or null
  /// when nobody named one — which on a roadside stop is the honest answer
  /// (`06-fleet-and-routes.md`).
  final String? stationName;
  final String? stationNotes;

  final List<LinkedSeat> seats;

  /// Which channel the link went out on. The step-up code goes to the same
  /// one, and the page says so — "we will text the number ending 47" is the
  /// difference between somebody waiting and somebody giving up.
  final String channel;

  final DateTime expiresAt;
}

/// The ticket you can always get to (ADR-0026).
///
/// Two callers with nothing in common: a vendor at a counter who wants the
/// customer to have their ticket, and a stranger holding a link. They are on
/// one port because they are the two ends of one thing — and keeping them
/// together is what makes it obvious that [open] must never answer with
/// anything [queueSend] would not have been willing to hand over.
abstract interface class TicketLinks {
  /// Queues a send. The token is **not** minted here.
  ///
  /// It is minted by the drain, in the transaction that composes the message
  /// — so the plaintext exists in exactly two places, the message and nowhere
  /// else, and never in a queue row somebody can read a week later.
  Future<Result<QueuedTicketLink, LinkRefusal>> queueSend({
    required String operatorId,
    required String bookingRef,
    required String channel,
    required String? sendTo,
    required String? byUserId,
    required DateTime now,
  });

  /// The holder's read. Anonymous, and counts the open.
  ///
  /// A revoked link, an expired one and a token nobody ever issued get the
  /// **same** answer. Telling whoever holds a dead link that it was once real
  /// is a conversation the traveller did not ask to start.
  Future<LinkedTicket?> open({required String token, required DateTime now});

  /// Where a step-up code may be sent, for a link that is still live.
  ///
  /// **The caller never supplies an address.** The one on the link is the one
  /// the ticket was delivered to, frozen at mint time — a traveller who later
  /// changes their email must not find that an old link now sends codes
  /// somewhere new, and an endpoint that accepted a destination would be an
  /// open relay with our domain on it.
  ///
  /// Null for a token that is unknown, revoked or expired: the same one
  /// answer [open] gives.
  Future<LinkDestination?> destinationFor(String token);

  /// Hands the booking to the account that just proved it holds the address.
  ///
  /// This is the line in ADR-0026 worth the most: it is how a walk-in becomes
  /// somebody with an account, without anybody selling them anything.
  ///
  /// Idempotent, and refused when the booking is already held by an account
  /// somebody has actually signed in to — the guichet's unverified account is
  /// what this is for, and a link is not enough to take a real person's
  /// booking away from them. Returns the reference it claimed, or null.
  Future<String?> claim({required String token, required String userId});

  /// Kills every live link on a booking. Idempotent.
  Future<Result<void, LinkRefusal>> revoke({
    required String operatorId,
    required String bookingRef,
    required DateTime now,
  });
}
