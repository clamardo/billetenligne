@Tags(['live'])
library;

import 'dart:io';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:test/test.dart';

/// The client against a real server.
///
/// The unit suite scripts the transport, so it proves what the client *sends*
/// and how it reads a reply it was handed. What it cannot prove is that those
/// two halves meet: that the URL the client builds is the route the server
/// mounted, that the header casing survives a socket, and that the JSON the
/// server actually emits parses into the DTOs the app renders.
///
/// Every one of those has broken in this repository already — a route mounted
/// at a directory index answered 404 without a trailing slash, and a header
/// read with canonical casing never matched. Neither is reachable from a test
/// that builds its own request.
///
/// Run by tool/smoke_api.sh, which starts the server first.
void main() {
  final baseUrl = Platform.environment['BEL_API_URL'];

  if (baseUrl == null || baseUrl.isEmpty) {
    test('live API', () {}, skip: 'run via tool/smoke_api.sh');
    return;
  }

  late BelApiClient client;

  setUpAll(() {
    client = BelApiClient(
      baseUrl: Uri.parse(baseUrl),
      token: () => 'fake:traveller',
      retry: RetryPolicy.none,
    );
  });

  tearDownAll(() => client.close());

  test('the whole funnel, over a socket', () async {
    final trips = await client.searchTrips(
      SearchDeparturesQuery(
        originCity: 'BZV',
        destinationCity: 'PNR',
        date: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
    );
    expect(trips, isNotEmpty, reason: 'the demo departure should be on sale');

    final departure = trips.first;
    // Money survived the wire as minor units rather than becoming a float.
    expect(departure.serviceFee.minor, 300);
    expect(departure.total.minor, departure.fare.minor + 300);

    final map = await client.seatMap(departure.id);
    expect(map.seats, isNotEmpty);
    expect(map.departureId, departure.id);

    final free = map.seats.firstWhere((s) => s.isSelectable);

    final hold = await client.createHold(
      CreateHoldRequest(departureId: departure.id, seatLabels: [free.label]),
    );
    expect(hold.seatLabels, [free.label]);
    expect(hold.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);

    // The seat the server just gave us reads as taken to everybody else.
    final afterHold = await client.seatMap(departure.id);
    expect(
      afterHold.seats.firstWhere((s) => s.label == free.label).status,
      SeatStatusDto.held,
    );

    await client.releaseHold(hold.id);

    final afterRelease = await client.seatMap(departure.id);
    expect(
      afterRelease.seats.firstWhere((s) => s.label == free.label).status,
      SeatStatusDto.available,
    );
  });

  test('a taken seat comes back as a typed refusal, not a crash', () async {
    final trips = await client.searchTrips(
      SearchDeparturesQuery(
        originCity: 'BZV',
        destinationCity: 'PNR',
        date: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
    );
    final departure = trips.first;
    final map = await client.seatMap(departure.id);
    final free = map.seats.lastWhere((s) => s.isSelectable);

    await client.createHold(
      CreateHoldRequest(departureId: departure.id, seatLabels: [free.label]),
    );

    final failure = await client
        .createHold(
          CreateHoldRequest(
            departureId: departure.id,
            seatLabels: [free.label],
          ),
        )
        .then<ApiFailure?>((_) => null, onError: (Object e) => e as ApiFailure);

    final refused = failure! as ServerRefused;
    expect(refused.status, 409);
    expect(refused.code, ErrorCode.seatUnavailable);
    // The app renders this key. A code the catalog does not know would show a
    // raw dotted string to a traveller.
    expect(refused.messageKey, 'errors.hold.seat_unavailable');
  });

  test('a retried hold returns the same hold, not a second one', () async {
    final trips = await client.searchTrips(
      SearchDeparturesQuery(
        originCity: 'BZV',
        destinationCity: 'PNR',
        date: DateTime.now().toUtc().add(const Duration(days: 1)),
      ),
    );
    final departure = trips.first;
    final map = await client.seatMap(departure.id);
    final free = map.seats.where((s) => s.isSelectable).elementAt(2);

    const key = 'live-retry-key';
    final first = await client.createHold(
      CreateHoldRequest(departureId: departure.id, seatLabels: [free.label]),
      idempotencyKey: key,
    );
    final replay = await client.createHold(
      CreateHoldRequest(departureId: departure.id, seatLabels: [free.label]),
      idempotencyKey: key,
    );

    expect(replay.id, first.id);
  });
}
