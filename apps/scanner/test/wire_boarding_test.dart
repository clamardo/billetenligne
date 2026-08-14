import 'dart:async';
import 'dart:convert';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_scanner/src/application/boarding_session.dart';
import 'package:bel_scanner/src/application/boarding_sync.dart';
import 'package:bel_scanner/src/application/road_progress.dart';
import 'package:bel_scanner/src/infrastructure/api_boarding_gateway.dart';
import 'package:bel_scanner/src/infrastructure/memory_redemption_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// The scanner against a real manifest off the wire.
///
/// The demo tests prove the door decides correctly. These prove the harder
/// half: that a manifest which arrived as JSON — base64 secrets, base64 public
/// keys, a signature the device has never seen before — boards a real
/// passenger. Everything between the response and the verdict runs for real;
/// only the socket is scripted.
void main() {
  const mac = HmacSha256Authenticator();
  final now = DateTime.utc(2026, 8, 15, 5, 40);
  final departsAt = DateTime.utc(2026, 8, 15, 6);

  late Ed25519TicketSigner signer;
  late String publicKeyB64;

  /// A ticket exactly as the traveller's screen would be showing it.
  Future<String> qrFor({
    required String ref,
    required String seat,
    required String name,
    required List<int> secret,
    String departureId = 'dep-1',
  }) async {
    final payload = TicketPayload(
      bookingRef: ref,
      seatLabel: seat,
      departureId: departureId,
      departsAt: departsAt,
      routeCode: 'BZV>PNR',
      operatorCode: 'ODN',
      passengerName: name,
      keyId: 1,
    );
    return payload.encode(
      await signer.sign(payload.signingBytes()),
      freshnessCode: RotatingCode.current(secret: secret, now: now, mac: mac),
    );
  }

  final aline = utf8.encode('secret:BEL-7QK4M2/14A');
  final firmin = utf8.encode('secret:BEL-T5W2YZ/3A');

  String manifestJson() => jsonEncode({
    'departureId': 'dep-1',
    'operatorCode': 'ODN',
    'routeCode': 'BZV>PNR',
    'departsAt': departsAt.toIso8601String(),
    'capacity': 49,
    'tickets': [
      {
        'bookingRef': 'BEL-7QK4M2',
        'seatLabel': '14A',
        'passengerName': 'Aline Mabiala',
        'secret': base64Encode(aline),
        'alightsAt': 'DOL',
      },
      {
        'bookingRef': 'BEL-T5W2YZ',
        'seatLabel': '3A',
        'passengerName': 'Firmin Massamba',
        'secret': base64Encode(firmin),
      },
    ],
    'voided': ['BEL-T5W2YZ/3A'],
    'keys': {'1': publicKeyB64},
    'waypoints': [
      {'stopId': 'stop-kinkala', 'name': 'Kinkala', 'offsetMinutes': 90},
      {
        'stopId': 'stop-dolisie',
        'name': 'Dolisie',
        'offsetMinutes': 400,
        // Already confirmed, by this handset before it was killed or by the
        // conductor at the other door.
        'passedAt': '2026-08-15T10:42:00.000Z',
      },
    ],
  });

  setUp(() async {
    signer = await Ed25519TicketSigner.fromSeed(
      utf8.encode('bel-dev-ticket-signing-seed-0000').sublist(0, 32),
    );
    publicKeyB64 = base64Encode(await signer.publicKeyBytes());
  });

  ({BoardingSession session, MemoryRedemptionLog log}) sessionFor(
    PinnedFixture pinned,
  ) {
    final log = MemoryRedemptionLog();
    return (
      session: BoardingSession(
        manifest: pinned.manifest,
        verifier: TicketVerifier(
          signatures: pinned.signatures,
          mac: mac,
          log: log,
        ),
        log: log,
        preparer: pinned.preparer,
        deviceId: 'handset-1',
        clock: FixedClock(now),
      ),
      log: log,
    );
  }

  Future<PinnedFixture> pin(_Scripted transport) async {
    final gateway = ApiBoardingGateway(
      BelApiClient(
        baseUrl: Uri.parse('https://api.test'),
        httpClient: transport,
        token: () async => 'tok',
      ),
      clock: FixedClock(now),
    );
    final pinned = await gateway.pin('dep-1');
    return PinnedFixture(
      manifest: pinned.manifest,
      signatures: pinned.signatures,
      preparer: pinned.preparer,
      gateway: gateway,
    );
  }

  group('a manifest off the wire', () {
    test('boards a genuine ticket the device has never seen', () async {
      final pinned = await pin(_Scripted([(200, manifestJson())]));
      final fixture = sessionFor(pinned);
      final qr = await qrFor(
        ref: 'BEL-7QK4M2',
        seat: '14A',
        name: 'Aline Mabiala',
        secret: aline,
      );

      // The async half of the signature check, on this one payload.
      await fixture.session.warm(qr);
      final outcome = fixture.session.scan(qr);

      expect(outcome.result, VerificationResult.valid);
      expect(outcome.payload!.passengerName, 'Aline Mabiala');
      // Carried by the manifest rather than the signed payload (ADR-0025).
      expect(outcome.entry!.alightsAt, 'DOL');
      expect(fixture.session.progress, '1 / 2');
    });

    test('is refused unwarmed, which is why warming exists', () async {
      // The verdict is a pure function of bytes already on the device, and
      // Ed25519 is not. Without the preparer the cache has never been asked
      // about this signature, so a genuine ticket reads as forged — the exact
      // failure a scanner in the field would have shown on every passenger.
      final pinned = await pin(_Scripted([(200, manifestJson())]));
      final log = MemoryRedemptionLog();
      final blind = BoardingSession(
        manifest: pinned.manifest,
        verifier: TicketVerifier(
          signatures: pinned.signatures,
          mac: mac,
          log: log,
        ),
        log: log,
        deviceId: 'handset-1',
        clock: FixedClock(now),
      );

      final qr = await qrFor(
        ref: 'BEL-7QK4M2',
        seat: '14A',
        name: 'Aline Mabiala',
        secret: aline,
      );
      await blind.warm(qr);

      expect(blind.scan(qr).result, VerificationResult.invalid);
    });

    test('refuses a ticket refunded before the device pinned it', () async {
      final pinned = await pin(_Scripted([(200, manifestJson())]));
      final fixture = sessionFor(pinned);
      final qr = await qrFor(
        ref: 'BEL-T5W2YZ',
        seat: '3A',
        name: 'Firmin Massamba',
        secret: firmin,
      );

      await fixture.session.warm(qr);
      expect(fixture.session.scan(qr).result, VerificationResult.voided);
    });

    test('carries the road and the moment it was pinned', () async {
      final pinned = await pin(_Scripted([(200, manifestJson())]));

      expect(pinned.manifest.routeCode, 'BZV>PNR');
      // The device's clock, because "how long ago did *this handset* hear"
      // is the question the conductor is asking.
      expect(pinned.manifest.ageAt(now), Duration.zero);
      expect(pinned.manifest.expected, 2);
    });
  });

  group('the outbox', () {
    test('goes up, and both answers leave it', () async {
      final transport = _Scripted([
        (200, manifestJson()),
        (200, '{"recorded":["BEL-7QK4M2/14A"],"unknown":["BEL-GONE/1A"]}'),
      ]);
      final pinned = await pin(transport);
      final fixture = sessionFor(pinned);

      final qr = await qrFor(
        ref: 'BEL-7QK4M2',
        seat: '14A',
        name: 'Aline Mabiala',
        secret: aline,
      );
      await fixture.session.warm(qr);
      fixture.session.scan(qr);

      final sync = BoardingSync(
        gateway: pinned.gateway,
        outbox: fixture.log,
        departureId: 'dep-1',
      );
      expect(sync.pendingCount, 1);

      final report = await sync.drain();

      expect(report.ok, isTrue);
      // Two keys settled although only one was queued: `unknown` is not a
      // failure to retry, and both are dropped from the outbox.
      expect(report.settled, 2);
      expect(sync.pendingCount, 0);
      expect(
        transport.requests.last.url.path,
        '/console/v1/departures/dep-1/redemptions',
      );
      expect(transport.bodies.last, contains('handset-1'));
    });

    test('keeps its rows when the send fails', () async {
      final transport = _Scripted([
        (200, manifestJson()),
        (503, '{"error":{"code":"unavailable"}}'),
        (503, '{"error":{"code":"unavailable"}}'),
        (503, '{"error":{"code":"unavailable"}}'),
        (503, '{"error":{"code":"unavailable"}}'),
      ]);
      final pinned = await pin(transport);
      final fixture = sessionFor(pinned);

      final qr = await qrFor(
        ref: 'BEL-7QK4M2',
        seat: '14A',
        name: 'Aline Mabiala',
        secret: aline,
      );
      await fixture.session.warm(qr);
      fixture.session.scan(qr);

      final sync = BoardingSync(
        gateway: pinned.gateway,
        outbox: fixture.log,
        departureId: 'dep-1',
      );
      final report = await sync.drain();

      expect(report.ok, isFalse);
      expect(report.stillPending, 1);
      // The passenger is on the coach either way. A failed send is a fact
      // about the network, never about who boarded.
      expect(fixture.session.boardedCount, 1);
    });

    test('an empty outbox does not touch the network', () async {
      final transport = _Scripted([(200, manifestJson())]);
      final pinned = await pin(transport);
      final fixture = sessionFor(pinned);

      final report = await BoardingSync(
        gateway: pinned.gateway,
        outbox: fixture.log,
        departureId: 'dep-1',
      ).drain();

      expect(report.settled, 0);
      expect(transport.requests, hasLength(1));
    });
  });

  group('the road', () {
    /// A gateway that has pinned dep-1, plus the road it came back with.
    Future<({ApiBoardingGateway gateway, List<WaypointDto> road})> pinRoad(
      _Scripted transport,
    ) async {
      final gateway = ApiBoardingGateway(
        BelApiClient(
          baseUrl: Uri.parse('https://api.test'),
          httpClient: transport,
          token: () async => 'tok',
        ),
        clock: FixedClock(now),
      );
      final pinned = await gateway.pin('dep-1');
      return (gateway: gateway, road: pinned.waypoints);
    }

    test('arrives with the manifest, in road order', () async {
      final pinned = await pinRoad(_Scripted([(200, manifestJson())]));

      // One request. The tap this list exists for happens four hours later
      // with no signal, so a road fetched on demand is a road that is never
      // there.
      expect(pinned.road, hasLength(2));
      expect(pinned.road.first.name, 'Kinkala');
      expect(pinned.road.first.offsetMinutes, 90);
      expect(pinned.road.first.passedAt, isNull);
      expect(pinned.road.last.passedAt, DateTime.utc(2026, 8, 15, 10, 42));
    });

    test('a place already behind the coach is not offered again', () async {
      final pinned = await pinRoad(_Scripted([(200, manifestJson())]));
      final outbox = MemoryCheckpointLog();

      final progress = RoadProgress(
        road: pinned.road,
        outbox: outbox,
        clock: FixedClock(now),
        deviceId: 'handset-1',
      );

      // Dolisie came back confirmed. A handset killed at lunch and relaunched
      // must not offer it again — and must not queue it, because the server
      // is where it came from.
      final dolisie = progress.points().last;
      expect(dolisie.isBehind, isTrue);
      expect(progress.confirm('stop-dolisie'), isFalse);
      expect(outbox.pending(), isEmpty);
      expect(progress.lastConfirmed?.name, 'Dolisie');
    });

    test('one tap goes up on the next window, with the device clock', () async {
      final transport = _Scripted([
        (200, manifestJson()),
        (200, '{"recorded":["stop-kinkala"],"unknown":[]}'),
      ]);
      final pinned = await pinRoad(transport);
      final outbox = MemoryCheckpointLog();

      final progress = RoadProgress(
        road: pinned.road,
        outbox: outbox,
        clock: FixedClock(now),
        deviceId: 'handset-1',
      );
      expect(progress.confirm('stop-kinkala'), isTrue);

      final sync = BoardingSync(
        gateway: pinned.gateway,
        outbox: MemoryRedemptionLog(),
        road: outbox,
        departureId: 'dep-1',
      );
      expect(sync.pendingCount, 1);

      final report = await sync.drain();

      expect(report.ok, isTrue);
      expect(report.checkpointsSettled, 1);
      expect(sync.pendingCount, 0);
      expect(
        transport.requests.last.url.path,
        '/console/v1/departures/dep-1/checkpoints',
      );
      // The conductor's clock, not ours. A checkpoint stamped with the hour
      // it happened to sync would report the coach an hour behind itself.
      expect(transport.bodies.last, contains(now.toIso8601String()));
      expect(transport.bodies.last, contains('handset-1'));
    });

    test('a second tap on the same place changes nothing', () async {
      final pinned = await pinRoad(_Scripted([(200, manifestJson())]));
      final outbox = MemoryCheckpointLog();

      final progress = RoadProgress(
        road: pinned.road,
        outbox: outbox,
        clock: FixedClock(now),
        deviceId: 'handset-1',
      );

      expect(progress.confirm('stop-kinkala'), isTrue);
      // A double tap on a moving coach means the same thing twice, and the
      // time worth keeping is the first one — the rule the server enforces by
      // primary key, held here so an offline handset behaves the same way.
      expect(progress.confirm('stop-kinkala'), isFalse);
      expect(outbox.pending(), hasLength(1));
      expect(outbox.confirmed()['stop-kinkala'], now);
    });

    test('an unsent tap survives a failed send', () async {
      final transport = _Scripted([
        (200, manifestJson()),
        (503, '{"error":{"code":"unavailable"}}'),
        (503, '{"error":{"code":"unavailable"}}'),
        (503, '{"error":{"code":"unavailable"}}'),
        (503, '{"error":{"code":"unavailable"}}'),
      ]);
      final pinned = await pinRoad(transport);
      final outbox = MemoryCheckpointLog();

      RoadProgress(
        road: pinned.road,
        outbox: outbox,
        clock: FixedClock(now),
      ).confirm('stop-kinkala');

      final report = await BoardingSync(
        gateway: pinned.gateway,
        outbox: MemoryRedemptionLog(),
        road: outbox,
        departureId: 'dep-1',
      ).drain();

      expect(report.ok, isFalse);
      expect(report.stillPending, 1);
      // Still confirmed on the handset. A failed send is a fact about the
      // network, never about where the coach has been.
      expect(outbox.confirmed(), contains('stop-kinkala'));
    });

    test('an empty road queue does not touch the network', () async {
      final transport = _Scripted([(200, manifestJson())]);
      final pinned = await pinRoad(transport);

      final report = await BoardingSync(
        gateway: pinned.gateway,
        outbox: MemoryRedemptionLog(),
        road: MemoryCheckpointLog(),
        departureId: 'dep-1',
      ).drain();

      expect(report.settled, 0);
      expect(report.checkpointsSettled, 0);
      expect(transport.requests, hasLength(1));
    });
  });

  test("the day's coaches are asked for by local date", () async {
    final transport = _Scripted([
      (
        200,
        '{"departures":[{"id":"dep-1","routeCode":"BZV>PNR",'
            '"originCity":"Brazzaville","destinationCity":"Pointe-Noire",'
            '"departsAt":"2026-08-15T06:00:00.000Z","expected":2,'
            '"capacity":49,"status":"scheduled"}]}',
      ),
    ]);
    final gateway = ApiBoardingGateway(
      BelApiClient(
        baseUrl: Uri.parse('https://api.test'),
        httpClient: transport,
        token: () async => 'tok',
      ),
      clock: FixedClock(now),
    );

    final coaches = await gateway.coachesOn(DateTime(2026, 8, 15));

    expect(coaches.single.id, 'dep-1');
    expect(transport.requests.single.url.query, 'date=2026-08-15');
  });
}

/// What `pin` handed back, plus the gateway that produced it.
final class PinnedFixture {
  const PinnedFixture({
    required this.manifest,
    required this.signatures,
    required this.preparer,
    required this.gateway,
  });

  final BoardingManifest manifest;
  final SignatureVerifier signatures;
  final SignaturePreparer? preparer;
  final ApiBoardingGateway gateway;
}

/// A scripted transport. The scanner talks to a response, not a server.
final class _Scripted extends http.BaseClient {
  _Scripted(this._responses);

  final List<(int, String)> _responses;
  final List<http.BaseRequest> requests = [];
  final List<String> bodies = [];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(request is http.Request ? request.body : '');

    final (status, body) = _responses[_index.clamp(0, _responses.length - 1)];
    _index++;

    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );
  }
}
