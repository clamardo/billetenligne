@Tags(['live'])
library;

import 'dart:io';

import 'package:bel_client/bel_client.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
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
    expect(
      trips.items,
      isNotEmpty,
      reason: 'the demo departure should be on sale',
    );

    final departure = trips.items.first;
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
    final departure = trips.items.first;
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
    final departure = trips.items.first;
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

  /// The second factor, end to end over a socket.
  ///
  /// This is the one place the whole loop is provable: enrol, take the secret
  /// the server generated, compute a code from it with a real HMAC-SHA1, and
  /// have the server accept it. curl cannot do the arithmetic and the unit
  /// suite never crosses the wire, so a base32 alphabet off by one character —
  /// or a window computed from local time instead of UTC — would survive both
  /// and fail on the first vendor's phone.
  group('the second factor', () {
    test('enrol, confirm, and be counted as enrolled', () async {
      // A traveller is not obliged to hold one. That is the line the design
      // draws, and it is drawn from the account rather than from the client.
      final before = await client.secondFactor();
      expect(before.required_, isFalse);

      final enrolment = await client.beginSecondFactor();
      expect(enrolment.recoveryCodes, hasLength(8));
      expect(enrolment.provisioningUri, startsWith('otpauth://totp/'));

      // Unconfirmed is not enrolled: the server must not count a secret
      // nobody has proven they can compute.
      expect((await client.secondFactor()).enrolled, isFalse);

      final code = Totp.compute(
        secret: Base32.decode(enrolment.secretBase32)!,
        counter: Totp.windowAt(DateTime.now().toUtc()),
        mac: const HmacSha256Authenticator(),
      );
      await client.confirmSecondFactor(code);

      final after = await client.secondFactor();
      expect(after.enrolled, isTrue);
      expect(after.recoveryCodesRemaining, 8);

      // And a live factor is not silently overwritten by a second enrolment.
      final replaced = await client.beginSecondFactor().then<ApiFailure?>(
        (_) => null,
        onError: (Object e) => e as ApiFailure,
      );
      expect((replaced! as ServerRefused).code, ErrorCode.mfaAlreadyEnrolled);

      await client.disableSecondFactor();
      expect((await client.secondFactor()).enrolled, isFalse);
    });

    test('a forged half-session names nobody', () async {
      final failure = await client
          .verifySecondFactor(
            const VerifySecondFactorRequest(
              mfaToken: 'forged.signature',
              code: '000000',
            ),
          )
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e as ApiFailure,
          );

      final refused = failure! as ServerRefused;
      expect(refused.status, 401);
      expect(refused.code, ErrorCode.mfaExpired);
      // The app renders this key; a code the catalog does not know would show
      // a raw dotted string to somebody trying to sign in.
      expect(refused.messageKey, 'errors.mfa.expired');
    });
  });
}
