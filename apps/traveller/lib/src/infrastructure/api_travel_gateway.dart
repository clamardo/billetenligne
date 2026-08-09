import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';

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
  Future<List<DepartureSummaryDto>> search(SearchDeparturesQuery query) =>
      _client.searchTrips(query);

  @override
  Future<SeatMapDto> seatMap(String departureId) =>
      _client.seatMap(departureId);

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
}
