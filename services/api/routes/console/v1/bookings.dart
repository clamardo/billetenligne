import 'dart:io';

import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/middleware/require.dart';
import 'package:bel_api/src/middleware/tenant_scope.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_api/src/ports/capability.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /console/v1/bookings` — the guichet.
///
/// Two shapes, told apart by what arrives:
///
///   * **`paymentCode`** — a traveller reserved on their phone and has walked
///     in to pay. The vendor types the five characters they read out.
///   * **`departureId` + `seatLabels` + `passengers`** — a walk-in. The vendor
///     sells across the counter.
///
/// The second one is where the interesting decision is. A walk-in gets a
/// **user account**, created from the phone number the vendor types anyway
/// (the ticket goes to it by SMS) and deliberately **not marked verified** —
/// a vendor identifies a traveller, they do not authenticate one. That account
/// then takes the same hold through the same code path as a phone sale, which
/// is what makes agency and digital sales reconcile against one another
/// instead of being two ledgers with a spreadsheet between them.
///
/// The alternative — a special "counter booking" that skips holds — is a back
/// door, and a back door in the sales path is where every inventory
/// discrepancy in this kind of system comes from.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final denied = Require.capability(context, Capability.bookingSell);
  if (denied != null) return denied;

  final trace = context.read<String>();
  final scope = context.read<TenantScope>();
  final services = context.read<Services>();
  final principal = context.read<Principal>();

  final body = await context.request.json() as Map<String, Object?>;

  final stationId = body['stationId'];
  if (stationId is! String || stationId.isEmpty) {
    return _badRequest(trace, 'stationId');
  }

  // A vendor is scoped to their station: the Pointe-Noire agent must not be
  // able to take money into the Brazzaville drawer, because that drawer is
  // counted by somebody else at the end of the shift.
  final wrongStation = Require.station(context, stationId);
  if (wrongStation != null) return wrongStation;

  // A counter sale creates a hold, and a hold needs a key: the till's network
  // drops mid-sale and the vendor taps again, and that must return the same
  // booking rather than a second one on different seats. Demanded from the
  // client rather than minted here, because only the client knows which taps
  // were the same attempt.
  final key = context.request.headers[BelHeaders.idempotencyKey];

  final code = body['paymentCode'];
  if (code is String && code.isNotEmpty) {
    return _collect(services, scope, principal, stationId, code, trace);
  }

  if (key == null || key.isEmpty) return _badRequest(trace, 'Idempotency-Key');

  return _counterSale(services, scope, principal, stationId, key, body, trace);
}

/// Collecting against a reservation made on a phone.
Future<Response> _collect(
  Services services,
  TenantScope scope,
  Principal principal,
  String stationId,
  String rawCode,
  String trace,
) async {
  // Normalised the way a vendor types it: a traveller says "oh", the vendor
  // types O, and Crockford folds it onto zero. Failing on that would be a
  // sale lost to a font.
  final parsed = PaymentCode.parse(rawCode);
  if (parsed case Err(:final failure)) {
    return _error(HttpStatus.notFound, failure.code, trace);
  }

  final booking = await services.bookings.byPaymentCode(
    code: parsed.valueOrNull!.value,
    operatorId: scope.operatorId,
  );

  // Unknown, expired, already collected, or another operator's. One answer:
  // a vendor cannot act differently on any of them, and distinguishing them
  // would let somebody probe for live codes across operators.
  if (booking == null) {
    return _error(HttpStatus.notFound, ErrorCode.bookingInvalidRef, trace);
  }

  return _capture(services, booking, stationId, principal, trace);
}

/// Selling across the counter to somebody standing there.
Future<Response> _counterSale(
  Services services,
  TenantScope scope,
  Principal principal,
  String stationId,
  String idempotencyKey,
  Map<String, Object?> body,
  String trace,
) async {
  final departureId = body['departureId'];
  final passengers = body['passengers'];

  if (departureId is! String) return _badRequest(trace, 'departureId');
  if (passengers is! List || passengers.isEmpty) {
    return _badRequest(trace, 'passengers');
  }

  final parsed = <PassengerDto>[];
  for (final entry in passengers) {
    if (entry is! Map) return _badRequest(trace, 'passengers');
    parsed.add(PassengerDto.fromJson(entry.cast<String, Object?>()));
  }

  final phone = body['buyerPhone'];
  if (phone is! String) return _badRequest(trace, 'buyerPhone');

  final number = PhoneNumber.parse(phone);
  if (number case Err(:final failure)) {
    return _error(HttpStatus.badRequest, failure.code, trace);
  }

  // The buyer becomes a user like any other. Unverified — the vendor typed
  // this number, its owner did not prove it — but real, so the ticket has
  // somewhere to go and the traveller can sign in later and find it.
  final buyer = await services.directory.forCounterSale(
    phone: number.valueOrNull!.e164,
    fullName: parsed.first.fullName,
  );

  final claimed = await services.holdSeats(
    departureId: departureId,
    seatLabels: [
      for (final p in parsed)
        if (p.seatLabel != null) p.seatLabel!,
    ],
    userId: buyer.id,
    // Scoped to the vendor, so two agents cannot collide on a key one of them
    // chose badly — and the same key returns the same hold, which is what
    // turns a till's dropped connection into a retry rather than a second
    // sale on different seats.
    idempotencyKey: 'guichet:${principal.userId}:$idempotencyKey',
  );

  if (claimed case Err(:final failure)) {
    return _error(Problem.statusFor(failure.code), failure.code, trace);
  }

  final reserved = await services.reserveBooking(
    holdId: claimed.valueOrNull!.id,
    userId: buyer.id,
    passengers: parsed,
    channel: 'agency',
  );

  if (reserved case Err(:final failure)) {
    return _error(Problem.statusFor(failure.code), failure.code, trace);
  }

  return _capture(services, reserved.valueOrNull!, stationId, principal, trace);
}

/// Take the money, sell the seats, post the ledger, issue the tickets.
Future<Response> _capture(
  Services services,
  BookingRecord booking,
  String stationId,
  Principal principal,
  String trace,
) async {
  final posting = Postings.cashSale(
    operatorId: booking.operatorId,
    stationId: stationId,
    fare: booking.fare,
    serviceFee: booking.serviceFee,
  );

  // The domain refuses an unbalanced movement before it reaches the database,
  // where a deferred constraint trigger refuses it again at COMMIT. Both, on
  // purpose: this one gives a typed failure, that one guarantees no path can
  // write a half-entry.
  if (posting case Err()) {
    return _error(
      HttpStatus.internalServerError,
      ErrorCode.internal,
      trace,
    );
  }

  final confirmed = await services.bookings.captureCash(
    bookingId: booking.id,
    operatorId: booking.operatorId,
    stationId: stationId,
    soldByUserId: principal.userId,
    posting: posting.valueOrNull!,
  );

  // Somebody else collected it between the read and the write. Conditional in
  // the database, so exactly one of two vendors wins — and the loser is told
  // so rather than charging the passenger a second time.
  if (confirmed == null) {
    return _error(HttpStatus.conflict, ErrorCode.conflict, trace);
  }

  return Response.json(
    statusCode: HttpStatus.created,
    body: {
      'id': confirmed.id,
      'ref': confirmed.ref.display,
      'state': confirmed.state,
      'departureId': confirmed.departureId,
      'total': Wire.money(confirmed.total),
      'fare': Wire.money(confirmed.fare),
      'serviceFee': Wire.money(confirmed.serviceFee),
      'passengers': [
        for (final seat in confirmed.seats)
          {
            'seatLabel': seat.seatLabel,
            'fullName': seat.passengerName,
            if (seat.passengerPhone != null) 'phone': seat.passengerPhone,
          },
      ],
      'tickets': [
        for (final ticket in confirmed.tickets)
          {
            'id': ticket.id,
            'seatLabel': ticket.seatLabel,
            'qrPayload': ticket.payload,
          },
      ],
    },
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Response _badRequest(String trace, String field) => Response.json(
  statusCode: HttpStatus.badRequest,
  body: ApiError(
    code: ErrorCode.badRequest,
    params: {'field': field},
    traceId: trace,
  ).toJson(),
  headers: {BelHeaders.traceId: trace},
);

Response _error(int status, String code, String trace) => Response.json(
  statusCode: status,
  body: ApiError(code: code, traceId: trace).toJson(),
  headers: {BelHeaders.traceId: trace},
);
