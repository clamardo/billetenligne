import 'dart:convert';

import 'package:bel_domain/bel_domain.dart';
import 'package:test/test.dart';

/// Deterministic stand-in for Ed25519. The real adapter uses a real curve;
/// what matters to these tests is that a wrong key or a tampered message
/// fails, which this reproduces exactly.
final class FakeSignatures implements SignatureVerifier, TicketSigner {
  FakeSignatures({this.activeKeyId = 1, Set<int>? trustedKeys})
    : _trusted = trustedKeys ?? {1};

  @override
  final int activeKeyId;
  final Set<int> _trusted;

  @override
  List<int> sign({required List<int> message, required int keyId}) =>
      utf8.encode('sig:$keyId:${_digest(message)}');

  @override
  bool verify({
    required List<int> message,
    required List<int> signature,
    required int keyId,
  }) {
    if (!_trusted.contains(keyId)) return false;
    final expected = utf8.encode('sig:$keyId:${_digest(message)}');
    if (expected.length != signature.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != signature[i]) return false;
    }
    return true;
  }

  static String _digest(List<int> m) {
    var h = 0xcbf29ce484222325;
    for (final b in m) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return (h & 0x7FFFFFFFFFFFFFFF).toRadixString(16);
  }
}

/// Not HMAC-SHA256, but deterministic, key-dependent and 32 bytes — enough to
/// exercise window arithmetic and truncation. The adapter swaps in the real
/// primitive behind the same port.
final class FakeMac implements MessageAuthenticator {
  @override
  List<int> hmacSha256({required List<int> key, required List<int> message}) {
    final out = <int>[];
    var h = 0xcbf29ce484222325;
    for (final b in [...key, 0x5c, ...message]) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    for (var i = 0; i < 32; i++) {
      h = ((h ^ (i + 1)) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
      out.add((h >> 24) & 0xff);
    }
    return out;
  }
}

final class MemoryRedemptionLog implements RedemptionLog {
  final Map<String, DateTime> _scans = {};
  final List<String> manualBoardings = [];

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
  }) {
    final key = BoardingManifest.keyFor(bookingRef, seatLabel);
    // First scan wins — that is the one a dispute is settled with.
    _scans.putIfAbsent(key, () => at);
    if (manual) manualBoardings.add(key);
  }
}

void main() {
  final departsAt = DateTime.utc(2026, 8, 15, 6);
  final atGate = DateTime.utc(2026, 8, 15, 5, 40);
  final secret = utf8.encode('per-ticket-secret-14A');

  late FakeSignatures signatures;
  late FakeMac mac;
  late MemoryRedemptionLog log;
  late TicketVerifier verifier;

  TicketPayload payloadFor({
    String bookingRef = '7QK4M2',
    String seat = '14A',
    String departureId = 'dep-001',
    String passenger = 'Aline M.',
    int keyId = 1,
  }) => TicketPayload(
    bookingRef: bookingRef,
    seatLabel: seat,
    departureId: departureId,
    departsAt: departsAt,
    routeCode: 'BZV>PNR',
    operatorCode: 'ODN',
    passengerName: passenger,
    keyId: keyId,
  );

  String issue(TicketPayload p) =>
      p.encode(signatures.sign(message: p.signingBytes(), keyId: p.keyId));

  BoardingManifest manifestWith({
    String departureId = 'dep-001',
    List<({String ref, String seat, String name})> seats = const [
      (ref: '7QK4M2', seat: '14A', name: 'Aline M.'),
    ],
    Set<String> voided = const {},
  }) => BoardingManifest(
    departureId: departureId,
    operatorCode: 'ODN',
    departsAt: departsAt,
    pinnedAt: atGate.subtract(const Duration(minutes: 20)),
    voidedTicketRefs: voided,
    entries: {
      for (final s in seats)
        BoardingManifest.keyFor(s.ref, s.seat): ManifestEntry(
          bookingRef: s.ref,
          seatLabel: s.seat,
          passengerName: s.name,
          rotatingSecret: secret,
        ),
    },
  );

  String codeNow([DateTime? at]) =>
      RotatingCode.current(secret: secret, now: at ?? atGate, mac: mac);

  setUp(() {
    signatures = FakeSignatures();
    mac = FakeMac();
    log = MemoryRedemptionLog();
    verifier = TicketVerifier(signatures: signatures, mac: mac, log: log);
  });

  group('payload encoding', () {
    test('round-trips exactly', () {
      final original = payloadFor();
      final encoded = issue(original);
      final decoded = TicketPayload.decode(encoded).valueOrNull!;

      expect(decoded.payload.bookingRef, '7QK4M2');
      expect(decoded.payload.seatLabel, '14A');
      expect(decoded.payload.departureId, 'dep-001');
      expect(decoded.payload.departsAt, departsAt);
      expect(decoded.payload.routeCode, 'BZV>PNR');
      expect(decoded.payload.passengerName, 'Aline M.');
      expect(decoded.payload.keyId, 1);
    });

    test('stays well under the QR density budget', () {
      // Above ~300 bytes a QR gets dense enough that a cracked screen in
      // daylight starts failing to scan. That is the real constraint.
      final encoded = issue(payloadFor(passenger: 'Marie-Claire Nzoubou'));
      expect(
        utf8.encode(encoded).length,
        lessThanOrEqualTo(TicketPayload.maxEncodedBytes),
      );
    });

    test('signing bytes are deterministic', () {
      // The server that signs and the device that verifies must produce byte
      // identical input, or every check fails for reasons nobody can
      // reproduce.
      expect(payloadFor().signingBytes(), payloadFor().signingBytes());
    });

    test('a separator in a passenger name cannot shift the fields', () {
      // "Jean|Marc" would otherwise displace every field after it and produce
      // a confidently wrong ticket.
      final encoded = issue(payloadFor(passenger: r'Jean|Marc \Nkou'));
      final decoded = TicketPayload.decode(encoded).valueOrNull!;
      expect(decoded.payload.passengerName, r'Jean|Marc \Nkou');
      expect(decoded.payload.keyId, 1, reason: 'later fields are intact');
    });

    test('rejects malformed input rather than guessing', () {
      for (final bad in ['', 'nonsense', 'a|b|c.sig', '1|BEL|X.not-base64!!']) {
        expect(TicketPayload.decode(bad).isErr, isTrue, reason: bad);
      }
    });

    test('a name containing a dot still parses', () {
      // "Aline M." is a perfectly ordinary passenger name, and it broke the
      // naive split-on-every-dot version immediately. Parsing from the right
      // is what makes it safe.
      final encoded = issue(payloadFor(passenger: 'Aline M.'));
      final decoded = TicketPayload.decode(encoded).valueOrNull!;
      expect(decoded.payload.passengerName, 'Aline M.');
      expect(decoded.freshnessCode, isNull);
    });

    test('a live ticket carries its freshness code inside the QR', () {
      // A camera reads one thing. Printing six digits beside the QR and asking
      // a conductor to type them would add ten seconds per passenger.
      final p = payloadFor();
      final encoded = p.encode(
        signatures.sign(message: p.signingBytes(), keyId: 1),
        freshnessCode: '418207',
      );
      final decoded = TicketPayload.decode(encoded).valueOrNull!;
      expect(decoded.freshnessCode, '418207');
      expect(decoded.payload.seatLabel, '14A');
    });

    test('a malformed freshness code is rejected, not ignored', () {
      final p = payloadFor();
      final base = p.encode(
        signatures.sign(message: p.signingBytes(), keyId: 1),
      );
      expect(TicketPayload.decode('$base.12345').isErr, isTrue);
      expect(TicketPayload.decode('$base.abcdef').isErr, isTrue);
    });

    test('refuses a future format version', () {
      // A scanner that misreads a format it does not know is worse than one
      // that says "update me".
      final future = issue(payloadFor()).replaceFirst('1|BEL', '2|BEL');
      final result = TicketPayload.decode(future);
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.code, 'ticket.malformed');
    });
  });

  group('the five verdicts', () {
    test('VALIDE — a genuine ticket at the right coach', () {
      final outcome = verifier.verify(
        scanned: issue(payloadFor()),
        manifest: manifestWith(),
        now: atGate,
        presentedCode: codeNow(),
      );

      expect(outcome.result, VerificationResult.valid);
      expect(outcome.boards, isTrue);
      expect(outcome.payload!.passengerName, 'Aline M.');
    });

    test('INVALIDE — a forged signature', () {
      final tampered = issue(payloadFor()).replaceFirst('14A', '14B');
      final outcome = verifier.verify(
        scanned: tampered,
        manifest: manifestWith(),
        now: atGate,
        presentedCode: codeNow(),
      );
      expect(outcome.result, VerificationResult.invalid);
      expect(outcome.boards, isFalse);
    });

    test('INVALIDE — signed with a key we do not trust', () {
      final rogue = FakeSignatures(activeKeyId: 9, trustedKeys: {9});
      final p = payloadFor(keyId: 9);
      final scanned = p.encode(rogue.sign(message: p.signingBytes(), keyId: 9));

      final outcome = verifier.verify(
        scanned: scanned,
        manifest: manifestWith(),
        now: atGate,
        presentedCode: codeNow(),
      );
      expect(outcome.result, VerificationResult.invalid);
    });

    test('MAUVAIS DÉPART — real ticket, different coach', () {
      final outcome = verifier.verify(
        scanned: issue(payloadFor(departureId: 'dep-999')),
        manifest: manifestWith(),
        now: atGate,
        presentedCode: codeNow(),
      );

      expect(outcome.result, VerificationResult.wrongDeparture);
      // The conductor needs to be able to say which coach to find.
      expect(outcome.detail, 'dep-999');
      expect(outcome.expectedDepartureId, 'dep-001');
      expect(outcome.payload!.passengerName, 'Aline M.');
      expect(outcome.result.isRecoverable, isTrue);
    });

    test('DÉJÀ EMBARQUÉ — scanned twice, with the first time', () {
      final scanned = issue(payloadFor());
      final firstAt = atGate;

      final first = verifier.verify(
        scanned: scanned,
        manifest: manifestWith(),
        now: firstAt,
        presentedCode: codeNow(firstAt),
      );
      expect(first.boards, isTrue);
      log.record(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        at: firstAt,
        deviceId: 'dev-1',
      );

      final laterAt = firstAt.add(const Duration(minutes: 3));
      final second = verifier.verify(
        scanned: scanned,
        manifest: manifestWith(),
        now: laterAt,
        presentedCode: codeNow(laterAt),
      );

      expect(second.result, VerificationResult.alreadyBoarded);
      // The usual cause is a double-tap by the conductor, not fraud — so the
      // screen shows when, and lets them judge.
      expect(second.firstScannedAt, firstAt);
    });

    test('a printed ticket boards without a live code', () {
      // Paper has no rotating code. Its defence against replay is the
      // redemption log, which makes it single-use — refusing it outright
      // would strand every passenger who printed their ticket.
      final outcome = verifier.verify(
        scanned: issue(payloadFor()),
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.valid);
      expect(outcome.detail, 'printed');
    });

    test('a live QR carries its own code, so the conductor types nothing', () {
      final p = payloadFor();
      final scanned = p.encode(
        signatures.sign(message: p.signingBytes(), keyId: 1),
        freshnessCode: codeNow(),
      );
      final outcome = verifier.verify(
        scanned: scanned,
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.valid);
    });

    test('a screenshot of a live QR carries a frozen code', () {
      final p = payloadFor();
      final scanned = p.encode(
        signatures.sign(message: p.signingBytes(), keyId: 1),
        freshnessCode: codeNow(atGate.subtract(const Duration(minutes: 10))),
      );
      final outcome = verifier.verify(
        scanned: scanned,
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.staleCode);
    });

    test('CODE PÉRIMÉ — a screenshot scans but its code is frozen', () {
      // This is the attack the rotating code exists to defeat. The QR is
      // genuine and verifies; the code beside it stopped changing.
      final screenshotCode = codeNow(atGate);
      final muchLater = atGate.add(const Duration(minutes: 10));

      final outcome = verifier.verify(
        scanned: issue(payloadFor()),
        manifest: manifestWith(),
        now: muchLater,
        presentedCode: screenshotCode,
      );

      expect(outcome.result, VerificationResult.staleCode);
      // Amber, not red: it prompts a refresh rather than accusing someone at
      // the door, because the common cause is a slow phone.
      expect(outcome.result.isRecoverable, isTrue);
      expect(outcome.payload, isNotNull);
    });

    test('ANNULÉ — refunded since the manifest was pinned', () {
      // A signature stays valid forever. Only the manifest knows the money
      // went back, which is why voiding happens at refund APPROVAL.
      final outcome = verifier.verify(
        scanned: issue(payloadFor()),
        manifest: manifestWith(voided: {'7QK4M2/14A'}),
        now: atGate,
        presentedCode: codeNow(),
      );
      expect(outcome.result, VerificationResult.voided);
    });

    test('PAS AU MANIFESTE — issued after the manifest was pinned', () {
      final outcome = verifier.verify(
        scanned: issue(payloadFor(bookingRef: 'LATE99')),
        manifest: manifestWith(),
        now: atGate,
        presentedCode: codeNow(),
      );
      expect(outcome.result, VerificationResult.notOnManifest);
    });
  });

  group('verdict ordering', () {
    test('already boarded outranks a stale code', () {
      // If the same ticket is presented twice, that fact matters more than
      // whether the second attempt happened to be fresh.
      log.record(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        at: atGate,
        deviceId: 'dev-1',
      );

      final outcome = verifier.verify(
        scanned: issue(payloadFor()),
        manifest: manifestWith(),
        now: atGate.add(const Duration(minutes: 20)),
        presentedCode: '000000',
      );
      expect(outcome.result, VerificationResult.alreadyBoarded);
    });

    test('wrong departure outranks everything about the passenger', () {
      log.record(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        at: atGate,
        deviceId: 'dev-1',
      );
      final outcome = verifier.verify(
        scanned: issue(payloadFor(departureId: 'dep-999')),
        manifest: manifestWith(),
        now: atGate,
        presentedCode: codeNow(),
      );
      expect(outcome.result, VerificationResult.wrongDeparture);
    });

    test('a bad signature short-circuits before any manifest lookup', () {
      final outcome = verifier.verify(
        scanned: '${payloadFor()._unused}',
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.invalid);
    });
  });

  group('rotating code', () {
    test('changes every 30 seconds', () {
      final a = codeNow(atGate);
      final b = codeNow(atGate.add(const Duration(seconds: 31)));
      expect(a, isNot(b));
    });

    test('is stable within its window', () {
      final base = DateTime.utc(2026, 8, 15, 5, 40, 0);
      expect(codeNow(base), codeNow(base.add(const Duration(seconds: 20))));
    });

    test('is always six digits', () {
      for (var i = 0; i < 200; i++) {
        final code = codeNow(atGate.add(Duration(seconds: i * 17)));
        expect(code, hasLength(6));
        expect(int.tryParse(code), isNotNull);
      }
    });

    test('differs per ticket secret', () {
      final other = RotatingCode.current(
        secret: utf8.encode('a-different-ticket'),
        now: atGate,
        mac: mac,
      );
      expect(codeNow(), isNot(other));
    });

    test('tolerates clock drift both ways', () {
      // Cheap handsets drift and conductors work where NTP never runs.
      // Refusing a valid passenger because our clock disagreed is the worse
      // failure by a wide margin.
      final issued = codeNow(atGate);
      for (final skew in [-90, -60, -30, 0, 30, 60, 90]) {
        expect(
          RotatingCode.isFresh(
            presented: issued,
            secret: secret,
            now: atGate.add(Duration(seconds: skew)),
            mac: mac,
          ),
          isTrue,
          reason: 'skew ${skew}s must still board',
        );
      }
    });

    test('rejects drift beyond tolerance', () {
      final issued = codeNow(atGate);
      expect(
        RotatingCode.isFresh(
          presented: issued,
          secret: secret,
          now: atGate.add(const Duration(minutes: 5)),
          mac: mac,
        ),
        isFalse,
      );
    });

    test('rejects a wrong-length code without touching the secret', () {
      expect(
        RotatingCode.isFresh(
          presented: '12345',
          secret: secret,
          now: atGate,
          mac: mac,
        ),
        isFalse,
      );
    });

    test('reports seconds left, for the live ring on the ticket', () {
      expect(
        RotatingCode.secondsRemaining(DateTime.utc(2026, 8, 15, 5, 40, 0)),
        30,
      );
      expect(
        RotatingCode.secondsRemaining(DateTime.utc(2026, 8, 15, 5, 40, 29)),
        1,
      );
    });
  });

  group('manual boarding — a dead phone must still travel', () {
    test('boards by reference against the offline manifest', () {
      final outcome = verifier.verifyManual(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.boards, isTrue);
      expect(outcome.detail, 'manual');
    });

    test('still refuses a refunded ticket', () {
      final outcome = verifier.verifyManual(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        manifest: manifestWith(voided: {'7QK4M2/14A'}),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.voided);
    });

    test('still catches a double boarding', () {
      log.record(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        at: atGate,
        deviceId: 'dev-1',
      );
      final outcome = verifier.verifyManual(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.alreadyBoarded);
    });

    test('an unknown reference is not on the manifest', () {
      final outcome = verifier.verifyManual(
        bookingRef: 'NOPE00',
        seatLabel: '1A',
        manifest: manifestWith(),
        now: atGate,
      );
      expect(outcome.result, VerificationResult.notOnManifest);
    });
  });

  group('the redemption log', () {
    test('keeps the first scan time, not the last', () {
      log.record(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        at: atGate,
        deviceId: 'dev-1',
      );
      log.record(
        bookingRef: '7QK4M2',
        seatLabel: '14A',
        at: atGate.add(const Duration(minutes: 5)),
        deviceId: 'dev-2',
      );
      expect(log.scannedAt('7QK4M2', '14A'), atGate);
    });
  });

  group('manifest', () {
    test('reports its own staleness so a conductor can re-sync', () {
      final m = manifestWith();
      expect(m.ageAt(atGate), const Duration(minutes: 20));
      expect(m.expected, 1);
    });
  });

  group('everything works with no network at all', () {
    test('a full boarding pass uses only local state', () {
      // Nothing in this test can reach a socket: the verifier holds a
      // signature checker, a MAC and a local log, and that is the whole
      // dependency list. This is the roadside guarantee.
      final manifest = manifestWith(
        seats: [
          (ref: '7QK4M2', seat: '14A', name: 'Aline M.'),
          (ref: '7QK4M2', seat: '14B', name: 'Pascal N.'),
          (ref: 'ZZ1188', seat: '2C', name: 'Marie K.'),
        ],
      );

      var boarded = 0;
      for (final seat in [
        ('7QK4M2', '14A'),
        ('7QK4M2', '14B'),
        ('ZZ1188', '2C'),
      ]) {
        final outcome = verifier.verify(
          scanned: issue(payloadFor(bookingRef: seat.$1, seat: seat.$2)),
          manifest: manifest,
          now: atGate,
          presentedCode: codeNow(),
        );
        expect(outcome.boards, isTrue, reason: '${seat.$1}/${seat.$2}');
        log.record(
          bookingRef: seat.$1,
          seatLabel: seat.$2,
          at: atGate,
          deviceId: 'dev-1',
        );
        boarded++;
      }

      expect(boarded, manifest.expected);
    });
  });
}

extension on TicketPayload {
  /// A payload with no signature at all — decoding must reject it.
  String get _unused => '${signingBytes().length}-not-a-ticket';
}
