import 'dart:math';

import 'package:bel_api/src/adapters/ed25519_ticket_issuer.dart';
import 'package:bel_api/src/application/hold_seats.dart';
import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/infrastructure/memory/memory_booking_store.dart';
import 'package:bel_api/src/infrastructure/memory/memory_seat_inventory.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

final class TestClock implements Clock {
  TestClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  late TestClock clock;
  late MemorySeatInventory inventory;
  late MemoryBookingStore bookings;
  late ReserveBooking reserve;
  late HoldSeats hold;

  setUp(() async {
    clock = TestClock(DateTime.utc(2026, 8, 9, 6));
    inventory = MemorySeatInventory(
      clock: clock,
      departures: [
        MemoryDeparture.coach(
          id: 'dep-1',
          operatorId: 'op-odn',
          departsAt: clock.now().add(const Duration(days: 1)),
        ),
      ],
    );
    bookings = MemoryBookingStore(
      inventory: inventory,
      issuer: await Ed25519TicketIssuer.development(
        random: Random(7),
      ),
      clock: clock,
    );
    reserve = ReserveBooking(
      bookings: bookings,
      random: Random(11),
    );
    hold = HoldSeats(inventory: inventory);
  });

  Future<String> holdSeats(List<String> labels, {String user = 'u-1'}) async {
    final result = await hold(
      departureId: 'dep-1',
      seatLabels: labels,
      userId: user,
      idempotencyKey: 'key-${labels.join()}-$user',
    );
    return result.valueOrNull!.id;
  }

  PassengerDto rider(String seat, [String name = 'Aline M.']) =>
      PassengerDto(fullName: name, seatLabel: seat);

  group('reserving', () {
    test('turns a hold into an unpaid booking with a payment code', () async {
      final holdId = await holdSeats(['1A']);

      final result = await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1A')],
      );

      final booking = result.valueOrNull!;
      expect(booking.state, 'pending_payment');
      expect(booking.paymentCode, hasLength(5));
      // Four hours: long enough to cross Brazzaville by taxi at rush hour,
      // short enough that a coach is not held all day by somebody who
      // changed their mind.
      expect(
        booking.paymentDeadline,
        clock.now().add(const Duration(hours: 4)),
      );
      // Nothing is ticketed before the money is taken. A ticket that exists
      // before payment is a ticket that can board before payment.
      expect(booking.tickets, isEmpty);
    });

    test('prices from inventory, never from the request', () async {
      final holdId = await holdSeats(['1A', '1B']);

      final booking = (await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1A'), rider('1B', 'Serge N.')],
      )).valueOrNull!;

      // The demo coach is 12 000 a seat with a 300 fee. No number in the
      // request could have said otherwise, because none travels.
      expect(booking.fare, const Money.xaf(24000));
      expect(booking.serviceFee, const Money.xaf(600));
      expect(booking.total, const Money.xaf(24600));
    });

    test('the fee is per seat, matching what the seat map quoted', () async {
      final one = await reserve(
        holdId: await holdSeats(['2A']),
        userId: 'u-1',
        passengers: [rider('2A')],
      );
      expect(one.valueOrNull!.serviceFee, const Money.xaf(300));
    });

    test('booking a seat that was not held is refused', () async {
      final holdId = await holdSeats(['1A']);

      // Hold 1A, book 1B. Not a plausible mistake; a plausible attack, and a
      // free seat if it worked.
      final result = await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1B')],
      );

      expect(result.failureOrNull, isA<HoldNoLongerUsable>());
    });

    test('fewer passengers than seats is refused', () async {
      final holdId = await holdSeats(['1A', '1B']);
      final result = await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1A')],
      );
      expect(result.failureOrNull, isA<HoldNoLongerUsable>());
    });

    test('two passengers on one seat is refused', () async {
      final holdId = await holdSeats(['1A', '1B']);
      final result = await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1A'), rider('1A', 'Serge N.')],
      );
      // The database would happily key (booking, seat) on the first of them
      // and silently drop the second.
      expect(result.failureOrNull, isA<PassengersDoNotMatchHold>());
    });

    test('a nameless passenger is refused', () async {
      final holdId = await holdSeats(['1A']);
      final result = await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1A', '   ')],
      );
      // A conductor reads this name against a face. A blank one is a ticket
      // nobody can check.
      expect(result.failureOrNull, isA<PassengerNameMissing>());
    });

    test("another traveller's hold cannot be booked", () async {
      final holdId = await holdSeats(['1A'], user: 'u-1');

      final result = await reserve(
        holdId: holdId,
        userId: 'u-2',
        passengers: [rider('1A')],
      );
      expect(result.failureOrNull, isA<HoldNoLongerUsable>());
    });

    test('a lapsed hold is refused', () async {
      final holdId = await holdSeats(['1A']);
      clock.advance(const Duration(minutes: 20));

      final result = await reserve(
        holdId: holdId,
        userId: 'u-1',
        passengers: [rider('1A')],
      );
      expect(result.failureOrNull, isA<HoldNoLongerUsable>());
    });

    test('an empty passenger list is refused', () async {
      final result = await reserve(
        holdId: await holdSeats(['1A']),
        userId: 'u-1',
        passengers: const [],
      );
      expect(result.failureOrNull, isA<PassengersDoNotMatchHold>());
    });
  });

  group('taking the cash', () {
    Future<BookingRecord> reserved() async => (await reserve(
      holdId: await holdSeats(['1A']),
      userId: 'u-1',
      passengers: [rider('1A')],
    )).valueOrNull!;

    test('confirms, posts the ledger and issues a ticket', () async {
      final booking = await reserved();

      final posting = Postings.cashSale(
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!;

      final confirmed = await bookings.captureCash(
        bookingId: booking.id,
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        soldByUserId: 'u-vendor',
        posting: posting,
      );

      expect(confirmed!.state, 'confirmed');
      expect(confirmed.tickets, hasLength(1));
      // A confirmed booking with no ledger row is indistinguishable from
      // theft at the end of the month.
      expect(bookings.postingFor(booking.id), isNotNull);
      expect(
        bookings.postingFor(booking.id),
        contains('debit cash:op-odn:st-bzv:till 12300'),
      );
    });

    test('the ticket verifies against the key that signed it', () async {
      final booking = await reserved();
      final confirmed = await bookings.captureCash(
        bookingId: booking.id,
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        soldByUserId: null,
        posting: Postings.cashSale(
          operatorId: booking.operatorId,
          stationId: 'st-bzv',
          fare: booking.fare,
          serviceFee: booking.serviceFee,
        ).valueOrNull!,
      );

      final decoded = TicketPayload.decode(confirmed!.tickets.single.payload);
      final payload = decoded.valueOrNull!.payload;

      expect(payload.bookingRef, booking.ref.value);
      expect(payload.seatLabel, '1A');
      expect(payload.passengerName, 'Aline M.');
      // Under 300 bytes, or the QR gets dense enough to start failing on a
      // cracked screen in daylight (ADR-0007).
      expect(
        confirmed.tickets.single.payload.length,
        lessThan(TicketPayload.maxEncodedBytes),
      );
    });

    test('a second capture of the same booking does nothing', () async {
      final booking = await reserved();
      final posting = Postings.cashSale(
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        fare: booking.fare,
        serviceFee: booking.serviceFee,
      ).valueOrNull!;

      final first = await bookings.captureCash(
        bookingId: booking.id,
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        soldByUserId: null,
        posting: posting,
      );
      final second = await bookings.captureCash(
        bookingId: booking.id,
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        soldByUserId: null,
        posting: posting,
      );

      // Two vendors collecting the same reservation at two counters must
      // produce one sale, not a passenger charged twice.
      expect(first, isNotNull);
      expect(second, isNull);
    });

    test("another operator cannot collect against this reservation", () async {
      final booking = await reserved();
      final captured = await bookings.captureCash(
        bookingId: booking.id,
        operatorId: 'op-someone-else',
        stationId: 'st-x',
        soldByUserId: null,
        posting: Postings.cashSale(
          operatorId: 'op-someone-else',
          stationId: 'st-x',
          fare: booking.fare,
          serviceFee: booking.serviceFee,
        ).valueOrNull!,
      );
      expect(captured, isNull);
    });

    test('the payment code is found while live and not after', () async {
      final booking = await reserved();

      expect(
        await bookings.byPaymentCode(
          code: booking.paymentCode!,
          operatorId: booking.operatorId,
        ),
        isNotNull,
      );

      await bookings.captureCash(
        bookingId: booking.id,
        operatorId: booking.operatorId,
        stationId: 'st-bzv',
        soldByUserId: null,
        posting: Postings.cashSale(
          operatorId: booking.operatorId,
          stationId: 'st-bzv',
          fare: booking.fare,
          serviceFee: booking.serviceFee,
        ).valueOrNull!,
      );

      // Erased on payment: it is a bearer, and one that outlives its purpose
      // is one somebody eventually finds.
      expect(
        await bookings.byPaymentCode(
          code: booking.paymentCode!,
          operatorId: booking.operatorId,
        ),
        isNull,
      );
    });
  });

  group('the payment code itself', () {
    test('uses the alphabet a vendor can type from dictation', () {
      final code = PaymentCode.generate(Random(3).nextInt);
      // Crockford base32: no I, L, O or U — the four characters people
      // confuse, which is the same reason airline record locators drop them.
      expect(code.value, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{5}$')));
    });

    test('folds what a vendor typed onto what was generated', () {
      // A traveller says "oh", the vendor types O. It must not fail.
      expect(PaymentCode.parse('o1lu2').valueOrNull!.value, '011V2');
      expect(PaymentCode.parse('  4k7-m2 ').valueOrNull!.value, '4K7M2');
    });

    test('refuses the wrong length rather than padding it', () {
      expect(PaymentCode.parse('4K7M').isErr, isTrue);
      expect(PaymentCode.parse('4K7M2X').isErr, isTrue);
    });
  });
}
