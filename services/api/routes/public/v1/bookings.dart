import 'dart:io';

import 'package:bel_api/src/application/ports/booking_store.dart';
import 'package:bel_api/src/application/reserve_booking.dart';
import 'package:bel_api/src/composition.dart';
import 'package:bel_api/src/middleware/idempotency.dart';
import 'package:bel_api/src/middleware/problem.dart';
import 'package:bel_api/src/ports/auth_gateway.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:dart_frog/dart_frog.dart';

/// `POST /public/v1/bookings` — reserve now, pay at the agency.
/// `GET  /public/v1/bookings` — the traveller's own bookings.
///
/// The POST is the second narrowest point in the funnel after the hold, and
/// the one where a mistake costs somebody a journey rather than a seat. Three
/// things it does that are easy to leave out:
///
///   * **Requires an idempotency key**, like the hold. A duplicate tap on a
///     dropped connection must not produce two reservations against one hold —
///     and the second would fail, leaving the traveller believing nothing
///     worked when in fact everything did.
///   * **Prices from the seat map, never from the body.** A seat can carry its
///     own fare, so a client-supplied number is a client-supplied discount.
///   * **Releases the idempotency claim when the work fails**, so a hold that
///     lapsed at 06:00:01 is retryable rather than "already answered" for a
///     day.
Future<Response> onRequest(RequestContext context) async {
  final trace = context.read<String>();
  final principal = context.read<Principal>();
  final services = context.read<Services>();

  if (principal.isAnonymous) {
    return _error(HttpStatus.unauthorized, Problem.unauthorized(traceId: trace), trace);
  }

  return switch (context.request.method) {
    HttpMethod.post => _reserve(context, services, principal, trace),
    HttpMethod.get => _list(services, principal, trace),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _list(
  Services services,
  Principal principal,
  String trace,
) async {
  final bookings = await services.bookings.forTraveller(principal.userId);
  return Response.json(
    body: {'items': [for (final b in bookings) _toDto(b).toJson()]},
    headers: {
      BelHeaders.traceId: trace,
      // A booking list contains a payment code and a passenger's name. A
      // shared cache holding either is a shared cache leaking both.
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

Future<Response> _reserve(
  RequestContext context,
  Services services,
  Principal principal,
  String trace,
) async {
  final body = await context.request.json() as Map<String, Object?>;
  final request = CreateBookingRequest.fromJson(body);

  final idempotency = services.idempotencyFor(principal.userId);
  final outcome = await idempotency.check(
    key: context.request.headers[BelHeaders.idempotencyKey],
    scope: 'bookings:${principal.userId}',
    body: body,
  );

  switch (outcome) {
    case ReplayStored(:final statusCode, :final body):
      return Response.json(
        statusCode: statusCode,
        body: body,
        headers: {BelHeaders.idempotencyReplayed: 'true'},
      );
    case MissingKey() || KeyReused() || StillInFlight():
      final error = Idempotency.errorFor(outcome, traceId: trace)!;
      return _error(Problem.statusFor(error.code), error, trace);
    case ProceedFresh(:final key):
      return _create(services, idempotency, key, request, principal, trace);
  }
}

Future<Response> _create(
  Services services,
  Idempotency idempotency,
  String key,
  CreateBookingRequest request,
  Principal principal,
  String trace,
) async {
  // No price is read here and none is sent. The fare comes from the seat row
  // inside the transaction that consumes the hold, which is what removes the
  // window between quoting a price and charging it.
  final result = await services.reserveBooking(
    holdId: request.holdId,
    userId: principal.userId,
    passengers: request.passengers,
  );

  return switch (result) {
    Ok(:final value) => await _complete(
      idempotency,
      key,
      _toDto(value).toJson(),
      trace,
    ),
    Err(:final ReserveBookingFailure failure) => await _fail(
      idempotency,
      key,
      failure,
      trace,
    ),
  };
}

Future<Response> _complete(
  Idempotency idempotency,
  String key,
  Map<String, Object?> body,
  String trace,
) async {
  await idempotency.record(key, HttpStatus.created, body);
  return Response.json(
    statusCode: HttpStatus.created,
    body: body,
    headers: {
      BelHeaders.traceId: trace,
      HttpHeaders.cacheControlHeader: 'private, no-store',
    },
  );
}

/// A refusal is NOT stored as the answer to this key.
///
/// "That hold lapsed" is a fact about one instant, not about this request.
/// Storing it would mean a traveller who retries after re-holding their seats
/// gets the stale refusal for a day.
Future<Response> _fail(
  Idempotency idempotency,
  String key,
  ReserveBookingFailure failure,
  String trace,
) async {
  await idempotency.abandon(key);
  final error = Problem.fromFailure(failure, traceId: trace);
  return _error(Problem.statusFor(error.code), error, trace);
}

BookingDto _toDto(BookingRecord record) => BookingDto(
  id: record.id,
  ref: record.ref.display,
  state: record.state,
  departureId: record.departureId,
  operatorName: record.trip.operatorName,
  originCity: record.trip.originCity,
  destinationCity: record.trip.destinationCity,
  departsAt: record.trip.departsAt,
  arrivesAt: record.trip.arrivesAt,
  passengers: [
    for (final seat in record.seats)
      PassengerDto(
        fullName: seat.passengerName,
        phone: seat.passengerPhone,
        idNumber: seat.passengerIdNumber,
        seatLabel: seat.seatLabel,
      ),
  ],
  fare: record.fare,
  serviceFee: record.serviceFee,
  total: record.total,
  createdAt: record.createdAt,
  paymentCode: record.paymentCode,
  paymentDeadline: record.paymentDeadline,
  tickets: const [],
);

Response _error(int status, ApiError error, String trace) => Response.json(
  statusCode: status,
  body: error.toJson(),
  headers: {BelHeaders.traceId: trace},
);
