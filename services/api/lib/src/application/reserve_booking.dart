import 'dart:math';

import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import 'ports/booking_store.dart';

sealed class ReserveBookingFailure extends DomainFailure {
  const ReserveBookingFailure();
}

/// The hold is gone — lapsed, released, already spent, or somebody else's.
///
/// **One failure for four causes.** The caller cannot act differently on any
/// of them (the answer is always "choose your seats again"), and telling a
/// stranger which it was tells them whether a hold id they found is live.
final class HoldNoLongerUsable extends ReserveBookingFailure {
  const HoldNoLongerUsable();
  @override
  String get code => ErrorCode.holdExpired;
}

/// The passenger list does not describe the seats that were held.
///
/// Without this check a client could hold 1A and book 1B, which is a free
/// seat. It is not a plausible mistake; it is a plausible attack.
final class PassengersDoNotMatchHold extends ReserveBookingFailure {
  const PassengersDoNotMatchHold();
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => const {'field': 'passengers'};
}

final class PassengerNameMissing extends ReserveBookingFailure {
  const PassengerNameMissing(this.seatLabel);
  final String seatLabel;
  @override
  String get code => ErrorCode.badRequest;
  @override
  Map<String, Object?> get params => {'field': 'passengers', 'seat': seatLabel};
}

/// Reserve now, pay at the agency (`04-payments.md` §4.4).
///
/// The whole cash-only pilot lives in the four hours this creates. A traveller
/// picks a seat on their phone, walks to an agency with the code, and a vendor
/// takes the money — which means the seat has to survive the walk without
/// being sold to somebody standing at the counter.
///
/// Three decisions carry that:
///
///   * **The seats stay `held`, not `sold`.** Selling before payment means a
///     ticket that can board before anybody has paid. There is no path from
///     an anonymous request to a sold seat, and this is not the exception.
///   * **No ledger rows are written.** No money has moved. Writing them now
///     and reversing them later is how a ledger stops being a record of what
///     happened and becomes a record of what we expected.
///   * **The deadline is the database's**, not this process's. Three API
///     instances with three slightly different clocks must not disagree about
///     whether a reservation is still payable.
final class ReserveBooking {
  ReserveBooking({
    required BookingStore bookings,
    this.market = Market.current,
    this.payWithin = const Duration(hours: 4),
    Random? random,
  }) : _bookings = bookings,
       _random = random ?? Random.secure();

  final BookingStore _bookings;
  final Market market;

  /// Four hours (`04-payments.md` §4.4). Long enough to cross Brazzaville by
  /// taxi at rush hour; short enough that a coach is not held all day by
  /// somebody who changed their mind.
  final Duration payWithin;

  final Random _random;

  Future<Result<BookingRecord, ReserveBookingFailure>> call({
    required String holdId,
    required String userId,
    required List<PassengerDto> passengers,
    String channel = 'app',
  }) async {
    if (passengers.isEmpty) return const Err(PassengersDoNotMatchHold());

    final named = <Passenger>[];
    final seen = <String>{};

    for (final passenger in passengers) {
      final label = passenger.seatLabel;
      if (label == null || label.isEmpty) {
        return const Err(PassengersDoNotMatchHold());
      }
      // Two passengers on one seat is a request that can only be a bug or an
      // attempt, and either way it must not reach a database that will
      // happily key `(booking, seat)` on the first of them.
      if (!seen.add(label)) return const Err(PassengersDoNotMatchHold());

      // The ticket carries this name and a conductor reads it aloud against a
      // face. A blank one is a ticket nobody can check.
      if (passenger.fullName.trim().isEmpty) {
        return Err(PassengerNameMissing(label));
      }

      named.add(
        Passenger(
          seatLabel: label,
          fullName: passenger.fullName.trim(),
          phone: passenger.phone,
          idNumber: passenger.idNumber,
        ),
      );
    }

    // No price crosses this boundary. The fare is read from the seat row
    // inside the transaction that consumes the hold, so there is no window
    // between quoting and charging — and no client-supplied number anywhere.
    final record = await _bookings.reserveFromHold(
      holdId: holdId,
      userId: userId,
      passengers: named,
      serviceFeePerSeat: market.serviceFee,
      paymentCode: PaymentCode.generate(_random.nextInt).value,
      payWithin: payWithin,
      channel: channel,
    );

    if (record == null) return const Err(HoldNoLongerUsable());
    return Ok(record);
  }
}
