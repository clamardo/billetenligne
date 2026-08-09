import 'dart:convert';

import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

void main() {
  final seed = List<int>.generate(32, (i) => i + 1);
  final otherSeed = List<int>.generate(32, (i) => 200 - i);

  late Ed25519TicketSigner signer;
  late Ed25519TicketVerifier verifier;

  final payload = TicketPayload(
    bookingRef: '7QK4M2',
    seatLabel: '14A',
    departureId: 'dep-001',
    departsAt: DateTime.utc(2026, 8, 15, 6),
    routeCode: 'BZV>PNR',
    operatorCode: 'ODN',
    passengerName: 'Aline M.',
    keyId: 1,
  );

  setUp(() async {
    signer = await Ed25519TicketSigner.fromSeed(seed);
    verifier = Ed25519TicketVerifier({1: await signer.publicKeyBytes()});
  });

  Future<bool> check(
    List<int> message,
    List<int> signature, {
    int keyId = 1,
  }) async {
    await verifier.prepare(
      message: message,
      signature: signature,
      keyId: keyId,
    );
    return verifier.verify(
      message: message,
      signature: signature,
      keyId: keyId,
    );
  }

  group('Ed25519 signing', () {
    test('a signature we produced verifies', () async {
      final message = payload.signingBytes();
      final signature = await signer.sign(message);
      expect(await check(message, signature), isTrue);
    });

    test('signatures are 64 bytes', () async {
      // This is why Ed25519 rather than ECDSA: the whole QR must stay under
      // 300 bytes, and 64 is what makes the budget comfortable.
      final signature = await signer.sign(payload.signingBytes());
      expect(signature, hasLength(64));
    });

    test('a tampered message fails', () async {
      final message = payload.signingBytes();
      final signature = await signer.sign(message);

      final forged = TicketPayload(
        bookingRef: payload.bookingRef,
        seatLabel: '14B', // upgraded themselves to the window seat
        departureId: payload.departureId,
        departsAt: payload.departsAt,
        routeCode: payload.routeCode,
        operatorCode: payload.operatorCode,
        passengerName: payload.passengerName,
        keyId: payload.keyId,
      ).signingBytes();

      expect(await check(forged, signature), isFalse);
    });

    test('a signature from another key fails', () async {
      final rogue = await Ed25519TicketSigner.fromSeed(otherSeed);
      final message = payload.signingBytes();
      final signature = await rogue.sign(message);
      expect(await check(message, signature), isFalse);
    });

    test('an unknown key id fails rather than throwing', () async {
      final message = payload.signingBytes();
      final signature = await signer.sign(message);
      expect(await check(message, signature, keyId: 99), isFalse);
    });

    test('a garbage signature fails without taking the scanner down', () async {
      // Mid-boarding, an exception is far worse than a rejection: it strands
      // sixty people while the conductor restarts an app.
      expect(
        await check(payload.signingBytes(), utf8.encode('nonsense')),
        isFalse,
      );
      expect(await check(payload.signingBytes(), const []), isFalse);
    });

    test('an unprepared payload is not trusted by default', () {
      // The synchronous port answers false unless verification actually ran.
      // Failing closed is the only safe default here.
      expect(
        verifier.verify(
          message: payload.signingBytes(),
          signature: List.filled(64, 0),
          keyId: 1,
        ),
        isFalse,
      );
    });
  });

  group('key rotation', () {
    test('a device can trust several keys at once', () async {
      // Old keys are retained until the last ticket signed with them has
      // departed, so rotation never strands a passenger.
      final next = await Ed25519TicketSigner.fromSeed(otherSeed, keyId: 2);
      verifier.trust(2, await next.publicKeyBytes());

      final oldTicket = payload.signingBytes();
      final oldSig = await signer.sign(oldTicket);
      final newSig = await next.sign(oldTicket);

      expect(await check(oldTicket, oldSig, keyId: 1), isTrue);
      expect(await check(oldTicket, newSig, keyId: 2), isTrue);
      expect(verifier.knownKeyIds, {1, 2});
    });

    test('a revoked key stops verifying', () async {
      final fresh = Ed25519TicketVerifier({});
      final signature = await signer.sign(payload.signingBytes());
      await fresh.prepare(
        message: payload.signingBytes(),
        signature: signature,
        keyId: 1,
      );
      expect(
        fresh.verify(
          message: payload.signingBytes(),
          signature: signature,
          keyId: 1,
        ),
        isFalse,
      );
    });
  });

  group('a fixed seed keeps local development sane', () {
    test('the same seed yields the same key', () async {
      final a = await Ed25519TicketSigner.fromSeed(seed);
      final b = await Ed25519TicketSigner.fromSeed(seed);
      expect(await a.publicKeyBytes(), await b.publicKeyBytes());
    });

    test('a ticket signed by a previous run still verifies', () async {
      // Without this, every emulator restart invalidates every ticket in the
      // seeded world and nobody can test boarding.
      final yesterday = await Ed25519TicketSigner.fromSeed(seed);
      final signature = await yesterday.sign(payload.signingBytes());
      expect(await check(payload.signingBytes(), signature), isTrue);
    });
  });

  group('HMAC-SHA256 for the rotating code', () {
    const mac = HmacSha256Authenticator();

    test('produces a 32-byte digest', () {
      final digest = mac.hmacSha256(
        key: utf8.encode('secret'),
        message: utf8.encode('1'),
      );
      expect(digest, hasLength(32));
    });

    test('is deterministic', () {
      final a = mac.hmacSha256(
        key: utf8.encode('secret'),
        message: utf8.encode('123'),
      );
      final b = mac.hmacSha256(
        key: utf8.encode('secret'),
        message: utf8.encode('123'),
      );
      expect(a, b);
    });

    test('depends on the key', () {
      final a = mac.hmacSha256(
        key: utf8.encode('k1'),
        message: utf8.encode('m'),
      );
      final b = mac.hmacSha256(
        key: utf8.encode('k2'),
        message: utf8.encode('m'),
      );
      expect(a, isNot(b));
    });

    test('matches the RFC 4231 test vector', () {
      // Trusting our own implementation because it "looks right" is how a
      // subtly wrong HMAC ships. This is the published vector.
      final digest = mac.hmacSha256(
        key: List.filled(20, 0x0b),
        message: utf8.encode('Hi There'),
      );
      final hex = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex,
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });
  });

  group('the real primitives drive the real verdicts', () {
    test('a genuine ticket boards; a screenshot goes stale', () async {
      const mac = HmacSha256Authenticator();
      final secret = utf8.encode('ticket-secret-14A');
      final atGate = DateTime.utc(2026, 8, 15, 5, 40);

      final message = payload.signingBytes();
      final signature = await signer.sign(message);
      final scanned = payload.encode(signature);

      await verifier.prepare(message: message, signature: signature, keyId: 1);

      final log = _Log();
      final ticketVerifier = TicketVerifier(
        signatures: verifier,
        mac: mac,
        log: log,
      );

      final manifest = BoardingManifest(
        departureId: 'dep-001',
        operatorCode: 'ODN',
        departsAt: payload.departsAt,
        entries: {
          '7QK4M2/14A': ManifestEntry(
            bookingRef: '7QK4M2',
            seatLabel: '14A',
            passengerName: 'Aline M.',
            rotatingSecret: secret,
          ),
        },
      );

      final live = RotatingCode.current(secret: secret, now: atGate, mac: mac);
      expect(
        ticketVerifier
            .verify(
              scanned: scanned,
              manifest: manifest,
              now: atGate,
              presentedCode: live,
            )
            .result,
        VerificationResult.valid,
      );

      // The same QR, ten minutes later, with the code frozen at capture time.
      expect(
        ticketVerifier
            .verify(
              scanned: scanned,
              manifest: manifest,
              now: atGate.add(const Duration(minutes: 10)),
              presentedCode: live,
            )
            .result,
        VerificationResult.staleCode,
      );
    });
  });
}

final class _Log implements RedemptionLog {
  final Map<String, DateTime> _scans = {};

  @override
  DateTime? scannedAt(String bookingRef, String seatLabel) =>
      _scans[BoardingManifest.keyFor(bookingRef, seatLabel)];

  @override
  void record({
    required String bookingRef,
    required String seatLabel,
    required DateTime at,
    required String deviceId,
    bool codeWasStale = false,
    bool manual = false,
  }) => _scans.putIfAbsent(
    BoardingManifest.keyFor(bookingRef, seatLabel),
    () => at,
  );
}
