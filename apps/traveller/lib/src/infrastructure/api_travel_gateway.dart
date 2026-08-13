import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_domain/bel_domain.dart';

import '../application/ports/travel_gateway.dart';

/// The real gateway: the shared typed client, nothing more.
///
/// Thin on purpose. Retries, idempotency headers, trace ids and the offline
/// taxonomy all live in `bel_client`, where the console and the back office
/// get them too — duplicating any of that here is how three surfaces end up
/// with three different answers to the same dropped connection.
final class ApiTravelGateway implements TravelGateway {
  const ApiTravelGateway(this._client);

  final BelApiClient _client;

  @override
  Future<List<CityDto>> cities() => _client.cities();

  @override
  Future<TripPageDto> search(SearchDeparturesQuery query) =>
      _client.searchTrips(query);

  @override
  Future<SeatMapDto> seatMap(String departureId, {String? from, String? to}) =>
      _client.seatMap(departureId, from: from, to: to);

  @override
  Future<SeatAlertDto> watchSeats(String departureId, {int seats = 1}) =>
      _client.watchSeats(departureId, seats: seats);

  @override
  Future<void> unwatchSeats(String departureId) =>
      _client.unwatchSeats(departureId);

  @override
  Future<List<SeatAlertDto>> seatAlerts() => _client.seatAlerts();

  @override
  Future<HoldDto> hold({
    required String departureId,
    required List<String> seatLabels,
    required String idempotencyKey,
  }) => _client.createHold(
    CreateHoldRequest(departureId: departureId, seatLabels: seatLabels),
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<void> release(String holdId) => _client.releaseHold(holdId);

  @override
  Future<List<BookingDto>> bookings() => _client.bookings();

  @override
  Future<TravelChoicesDto> travelOptions(String bookingRef) =>
      _client.travelOptions(bookingRef);

  @override
  Future<ChoiceAppliedDto> chooseTravel({
    required String bookingRef,
    required String optionId,
  }) => _client.chooseTravel(
    bookingRef: bookingRef,
    request: TravelChoiceRequest(optionId: optionId),
  );

  @override
  Future<BookingDto> booking(String bookingId) async {
    final all = await _client.bookings();
    return all.firstWhere((b) => b.id == bookingId);
  }

  @override
  Future<TripShareDto> shareTrip(String bookingRef) =>
      _client.shareTrip(bookingRef);

  @override
  Future<TripShareDto?> tripShare(String bookingRef) =>
      _client.tripShare(bookingRef);

  @override
  Future<void> revokeTripShare(String bookingRef) =>
      _client.revokeTripShare(bookingRef);

  @override
  Future<CancellationOfferDto> cancellationOffer(String bookingRef) =>
      _client.cancellationOffer(bookingRef);

  @override
  Future<CancellationDoneDto> cancelBooking(String bookingRef) =>
      _client.cancelBooking(bookingRef);

  @override
  Future<ChangeOptionsDto> changeOptions(String bookingRef) =>
      _client.changeOptions(bookingRef);

  @override
  Future<ChangeAppliedDto> changeDeparture({
    required String bookingRef,
    required String departureId,
  }) =>
      _client.changeDeparture(bookingRef: bookingRef, departureId: departureId);

  @override
  Future<ChangeOrderDto> orderChange({
    required String bookingRef,
    required String departureId,
  }) => _client.orderChange(bookingRef: bookingRef, departureId: departureId);

  @override
  Future<void> cancelChangeOrder(String bookingRef) =>
      _client.cancelChangeOrder(bookingRef);

  @override
  Future<
    ({List<PaymentOptionDto> options, String? accountMsisdn, Money amount})
  >
  paymentOptions(String bookingId, {String? changeId}) =>
      _client.paymentOptions(bookingId, changeId: changeId);

  @override
  Future<PaymentIntentDto> startPayment({
    required String bookingId,
    required String railId,
    required String idempotencyKey,
    String? payerMsisdn,
    String? changeId,
    String? returnUrl,
  }) => _client.startPayment(
    StartPaymentRequest(
      bookingId: bookingId,
      railId: railId,
      payerMsisdn: payerMsisdn,
      changeId: changeId,
      returnUrl: returnUrl,
    ),
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<PaymentIntentDto> paymentStatus(String intentId) =>
      _client.paymentStatus(intentId);

  @override
  Future<BookingDto> reserve({
    required String holdId,
    required List<PassengerDto> passengers,
    required String idempotencyKey,
  }) => _client.createBooking(
    CreateBookingRequest(holdId: holdId, passengers: passengers),
    idempotencyKey: idempotencyKey,
  );
}
