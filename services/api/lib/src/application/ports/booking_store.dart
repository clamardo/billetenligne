import 'package:bel_domain/bel_domain.dart';

/// Who is travelling in which seat.
///
/// Carries no price, and that is deliberate: the fare is read from the seat
/// row inside the transaction that consumes the hold, so there is no window
/// between quoting a price and charging it. A price that travels through the
/// application layer is a price something can change on the way.
final class Passenger {
  const Passenger({
    required this.seatLabel,
    required this.fullName,
    this.phone,
    this.idNumber,
  });

  final String seatLabel;
  final String fullName;

  /// Distinct from the purchaser's account. This one field is what makes
  /// "buy a ticket for my mother" a first-class flow rather than a hack: she
  /// gets the ticket by SMS and needs no account to travel.
  final String? phone;

  final String? idNumber;
}

/// A seat on a booking, priced.
final class BookedSeat {
  const BookedSeat({
    required this.seatLabel,
    required this.passengerName,
    required this.fare,
    this.passengerPhone,
    this.passengerIdNumber,
  });

  final String seatLabel;
  final String passengerName;
  final Money fare;
  final String? passengerPhone;
  final String? passengerIdNumber;
}

/// A ticket, as issued.
final class IssuedTicket {
  const IssuedTicket({
    required this.id,
    required this.seatLabel,
    required this.payload,
    required this.keyId,
  });

  final String id;
  final String seatLabel;

  /// base45(CBOR) + Ed25519 signature, under 300 bytes so the QR stays low
  /// density and scans fast on a cracked screen in daylight (ADR-0007).
  final String payload;
  final int keyId;
}

/// A booking, as the application layer knows it.
final class BookingRecord {
  const BookingRecord({
    required this.id,
    required this.ref,
    required this.operatorId,
    required this.departureId,
    required this.state,
    required this.seats,
    required this.fare,
    required this.serviceFee,
    required this.total,
    required this.trip,
    required this.createdAt,
    this.paymentCode,
    this.paymentDeadline,
    this.tickets = const [],
  });

  final String id;
  final BookingRef ref;
  final String operatorId;
  final String departureId;

  /// `pending_payment` | `confirmed` | `cancelled` | `refunded` | `expired`.
  final String state;

  final List<BookedSeat> seats;
  final Money fare;
  final Money serviceFee;
  final Money total;

  /// Enough of the journey to render a booking without a second call.
  ///
  /// Denormalised onto the record rather than fetched by the caller, for the
  /// same reason migration 0006 pushed the transport mode onto `departures`:
  /// this is a read a traveller makes while standing in a queue, and one
  /// round trip on a 2G handshake is eight seconds.
  final TripSummary trip;

  final DateTime createdAt;

  /// What the traveller reads to the vendor. Present only while unpaid — it is
  /// a bearer, and a bearer that outlives its purpose is a bearer somebody
  /// eventually finds.
  final String? paymentCode;
  final DateTime? paymentDeadline;

  /// Empty until the money is taken. A ticket that exists before payment is a
  /// ticket that can board before payment.
  final List<IssuedTicket> tickets;

  bool get isConfirmed => state == 'confirmed';
}

/// The journey a booking is for.
final class TripSummary {
  const TripSummary({
    required this.operatorName,
    required this.operatorCode,
    required this.originCity,
    required this.destinationCity,
    required this.departsAt,
    required this.arrivesAt,
    required this.routeCode,
  });

  final String operatorName;
  final String operatorCode;
  final String originCity;
  final String destinationCity;
  final DateTime departsAt;
  final DateTime arrivesAt;
  final String routeCode;
}

/// Turning inventory into money, and money into a ticket.
///
/// Every method here is **one database transaction**, and that is the whole
/// design rather than an implementation note. Confirming a booking has to
/// move a seat to `sold`, write the booking, write the ledger and issue the
/// ticket — and any prefix of that list committing on its own is a specific,
/// nameable disaster:
///
///   * seat sold, no booking → inventory lost, nobody can board
///   * booking, no ledger → a confirmed sale with no money anywhere, which at
///     the end of the month is indistinguishable from theft
///   * ledger, no ticket → a paying passenger left at the roadside
///
/// So there is no method here that does one of them.
abstract interface class BookingStore {
  /// Reserve: turn an active hold into an unpaid booking.
  ///
  /// The seats stay `held` rather than becoming `sold`, and the hold's expiry
  /// is pushed out to the payment deadline. No ledger rows, because no money
  /// has moved — writing them now and reversing them later is how a ledger
  /// stops being a record of what happened.
  /// [serviceFeePerSeat] rather than a total, because the total depends on how
  /// many seats the hold actually covers — and only this method knows that.
  Future<BookingRecord?> reserveFromHold({
    required String holdId,
    required String userId,
    required List<Passenger> passengers,
    required Money serviceFeePerSeat,
    required String paymentCode,
    required Duration payWithin,
    required String channel,
  });

  /// Take the cash, sell the seats, post the ledger, issue the tickets.
  ///
  /// Runs under the **operator's** scope, not the traveller's: `bel_public`
  /// physically cannot write `sold` (migration 0005), because there must be no
  /// path from an anonymous internet request to a sold seat. Selling is a
  /// system action that happens after money is captured.
  Future<BookingRecord?> captureCash({
    required String bookingId,
    required String operatorId,
    required String stationId,
    required String? soldByUserId,
    required LedgerTransaction posting,
  });

  /// Confirms a booking whose mobile money payment settled.
  ///
  /// The twin of [captureCash] and deliberately a separate method rather than
  /// a parameter: cash names a till and a vendor, a rail names an intent, and
  /// the ledger postings are genuinely different — cash carries no commission
  /// and a rail nets it at source. Collapsing them into one method with four
  /// nullable arguments would make both harder to read and neither safer.
  ///
  /// Conditional on `pending_payment`, so a duplicate callback and a poll
  /// arriving together produce one confirmation, one set of ledger rows and
  /// one ticket.
  Future<BookingRecord?> captureRail({
    required String bookingId,
    required String operatorId,
    required String railId,
    required String intentId,
    required LedgerTransaction posting,
  });

  /// Finds an unpaid booking by the code the traveller reads to the vendor.
  ///
  /// Scoped to the operator doing the asking, so one operator's vendor cannot
  /// collect against another's reservation.
  Future<BookingRecord?> byPaymentCode({
    required String code,
    required String operatorId,
  });

  Future<BookingRecord?> byId({
    required String bookingId,
    required String operatorId,
  });

  /// A traveller's own bookings, newest first.
  Future<List<BookingRecord>> forTraveller(String userId, {int limit = 50});
}
