import 'package:bel_domain/bel_domain.dart';

import '../../application/ports/booking_store.dart';
import 'memory_seat_inventory.dart';
import '../../application/ports/ticket_issuer.dart';

/// Bookings in a map, over the in-memory inventory.
///
/// A faithful twin of the Postgres store in the ways that decide behaviour —
/// the hold is consumed conditionally, the capture is conditional on
/// `pending_payment`, the payment code is erased on payment — and honestly not
/// a twin in the way that matters most: there is no transaction here, so the
/// "all of it or none of it" guarantee the port promises is proven against
/// real Postgres and asserted nowhere else.
final class MemoryBookingStore implements BookingStore {
  MemoryBookingStore({
    required MemorySeatInventory inventory,
    required TicketIssuer issuer,
    Clock clock = const SystemClock(),
  }) : _inventory = inventory,
       _issuer = issuer,
       _clock = clock;

  final MemorySeatInventory _inventory;
  final TicketIssuer _issuer;
  final Clock _clock;

  final Map<String, BookingRecord> _byId = {};
  final Map<String, String> _ledgerByBooking = {};
  var _next = 0;

  /// What the ledger would have recorded. Exposed so a test can assert that a
  /// confirmed booking has a posting — the invariant whose absence is
  /// indistinguishable from theft at the end of the month.
  String? postingFor(String bookingId) => _ledgerByBooking[bookingId];

  @override
  Future<BookingRecord?> reserveFromHold({
    required String holdId,
    required String userId,
    required List<Passenger> passengers,
    required Money serviceFeePerSeat,
    required String paymentCode,
    required Duration payWithin,
    required String channel,
  }) async {
    final hold = _inventory.holdView(holdId);
    if (hold == null || hold.userId != userId) return null;
    if (hold.state != 'active') return null;
    if (!hold.expiresAt.isAfter(_clock.now())) return null;

    final held = hold.seatLabels.toSet();
    if (passengers.length != held.length) return null;
    for (final passenger in passengers) {
      if (!held.contains(passenger.seatLabel)) return null;
    }

    // Priced from the inventory, mirroring the real adapter's read of the
    // seat row rather than trusting anything the caller passed.
    final seats = <BookedSeat>[];
    for (final passenger in passengers) {
      final fare = _inventory.fareFor(hold.departureId, passenger.seatLabel);
      if (fare == null) return null;
      seats.add(
        BookedSeat(
          seatLabel: passenger.seatLabel,
          passengerName: passenger.fullName,
          passengerPhone: passenger.phone,
          passengerIdNumber: passenger.idNumber,
          fare: fare,
        ),
      );
    }

    final currency = seats.first.fare.currency;
    final fare = seats.fold(Money(0, currency), (sum, s) => sum + s.fare);
    final serviceFee = Money(
      serviceFeePerSeat.minor * seats.length,
      currency,
    );

    final record = BookingRecord(
      id: 'bk-mem-${++_next}',
      ref: BookingRef.generate((max) => (_next * 7 + max) % max),
      operatorId: hold.operatorId,
      departureId: hold.departureId,
      state: 'pending_payment',
      seats: seats,
      fare: fare,
      serviceFee: serviceFee,
      total: fare + serviceFee,
      trip: _demoTrip(hold.departureId),
      createdAt: _clock.now(),
      paymentCode: paymentCode,
      paymentDeadline: _clock.now().add(payWithin),
    );

    _byId[record.id] = record;
    return record;
  }

  @override
  Future<BookingRecord?> captureRail({
    required String bookingId,
    required String operatorId,
    required String railId,
    required String intentId,
    required LedgerTransaction posting,
  }) => captureCash(
    bookingId: bookingId,
    operatorId: operatorId,
    stationId: 'rail:$railId',
    soldByUserId: null,
    posting: posting,
  );

  @override
  Future<BookingRecord?> captureCash({
    required String bookingId,
    required String operatorId,
    required String stationId,
    required String? soldByUserId,
    required LedgerTransaction posting,
  }) async {
    final existing = _byId[bookingId];
    if (existing == null || existing.state != 'pending_payment') return null;
    if (existing.operatorId != operatorId) return null;

    final signed = await _issuer.issue(
      bookingRef: existing.ref,
      departureId: existing.departureId,
      departsAt: existing.trip.departsAt,
      routeCode: existing.trip.routeCode,
      operatorCode: existing.trip.operatorCode,
      seats: [
        for (final s in existing.seats)
          (seatLabel: s.seatLabel, passengerName: s.passengerName),
      ],
    );

    final confirmed = BookingRecord(
      id: existing.id,
      ref: existing.ref,
      operatorId: existing.operatorId,
      departureId: existing.departureId,
      state: 'confirmed',
      seats: existing.seats,
      fare: existing.fare,
      serviceFee: existing.serviceFee,
      total: existing.total,
      trip: existing.trip,
      createdAt: existing.createdAt,
      // Erased on payment. It is a bearer, and one that outlives its purpose
      // is one somebody eventually finds.
      tickets: [
        for (var i = 0; i < signed.length; i++)
          IssuedTicket(
            id: 'tk-mem-${existing.id}-$i',
            seatLabel: signed[i].seatLabel,
            payload: signed[i].payload,
            keyId: signed[i].keyId,
            rotatingSecret: signed[i].rotatingSecret,
            issuedAt: _clock.now(),
          ),
      ],
    );

    _byId[bookingId] = confirmed;
    _ledgerByBooking[bookingId] = posting.entries
        .map((e) => '${e.direction.name} ${e.account} ${e.amount.minor}')
        .join('; ');

    return confirmed;
  }

  @override
  Future<BookingRecord?> byPaymentCode({
    required String code,
    required String operatorId,
  }) async {
    for (final booking in _byId.values) {
      if (booking.paymentCode == code &&
          booking.operatorId == operatorId &&
          booking.state == 'pending_payment') {
        return booking;
      }
    }
    return null;
  }

  @override
  Future<BookingRecord?> byId({
    required String bookingId,
    required String operatorId,
  }) async {
    final booking = _byId[bookingId];
    return booking?.operatorId == operatorId ? booking : null;
  }

  /// Any booking, regardless of who owns it.
  ///
  /// The fake's stand-in for a query that runs under a different scope in the
  /// real store — the payment store opens an intent as the traveller and
  /// reads the booking in the same statement, which a map cannot express.
  Future<BookingRecord?> byIdUnscoped(String bookingId) async =>
      _byId[bookingId];

  @override
  Future<List<BookingRecord>> forTraveller(String userId, {int limit = 50}) =>
      Future.value(_byId.values.toList().reversed.take(limit).toList());

  TripSummary _demoTrip(String departureId) => TripSummary(
    operatorName: 'Ocean du Nord',
    operatorCode: 'ODN',
    originCity: 'BZV',
    destinationCity: 'PNR',
    departsAt: _clock.now().add(const Duration(days: 1)),
    arrivesAt: _clock.now().add(const Duration(days: 1, hours: 8)),
    routeCode: 'BZV-PNR',
  );
}
