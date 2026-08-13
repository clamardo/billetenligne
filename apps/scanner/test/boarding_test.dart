import 'package:bel_crypto/bel_crypto.dart';
import 'package:bel_domain/bel_domain.dart';
import 'package:bel_scanner/src/application/boarding_session.dart';
import 'package:bel_scanner/src/infrastructure/demo_data.dart';
import 'package:bel_scanner/src/infrastructure/memory_redemption_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DemoDeparture demo;
  late MemoryRedemptionLog log;
  late BoardingSession session;
  late DateTime now;

  const mac = HmacSha256Authenticator();

  String ticket(String ref, String seat) =>
      demo.tickets[BoardingManifest.keyFor(ref, seat)]!;

  String liveCode(String ref, String seat, [DateTime? at]) =>
      RotatingCode.current(
        secret: demo.secrets[BoardingManifest.keyFor(ref, seat)]!,
        now: at ?? now,
        mac: mac,
      );

  setUp(() async {
    now = DateTime.utc(2026, 8, 15, 5, 40);
    demo = await DemoDeparture.build(
      departsAt: now.add(const Duration(minutes: 20)),
    );
    log = MemoryRedemptionLog();
    session = BoardingSession(
      manifest: demo.manifest,
      verifier: TicketVerifier(signatures: demo.verifier, mac: mac, log: log),
      log: log,
      deviceId: 'test-device',
      clock: FixedClock(now),
    );
  });

  group('a normal boarding', () {
    test('a genuine ticket boards and increments the count', () {
      expect(session.boardedCount, 0);

      final outcome = session.scan(
        ticket('7QK4M2', '14A'),
        presentedCode: liveCode('7QK4M2', '14A'),
      );

      expect(outcome.result, VerificationResult.valid);
      expect(outcome.payload!.passengerName, 'Aline Mabiala');
      expect(session.boardedCount, 1);
      expect(session.progress, '1 / 8');
    });

    test('the same ticket a second time is refused with the first time', () {
      final code = liveCode('7QK4M2', '14A');
      session.scan(ticket('7QK4M2', '14A'), presentedCode: code);

      final second = session.scan(ticket('7QK4M2', '14A'), presentedCode: code);

      expect(second.result, VerificationResult.alreadyBoarded);
      expect(second.firstScannedAt, now);
      expect(session.boardedCount, 1, reason: 'no double count');
    });

    test('two passengers on one booking board separately', () {
      session.scan(
        ticket('7QK4M2', '14A'),
        presentedCode: liveCode('7QK4M2', '14A'),
      );
      final second = session.scan(
        ticket('7QK4M2', '14B'),
        presentedCode: liveCode('7QK4M2', '14B'),
      );

      expect(second.result, VerificationResult.valid);
      expect(second.payload!.passengerName, 'Pascal Nkouka');
      expect(session.boardedCount, 2);
    });
  });

  group('the verdicts a conductor actually meets', () {
    test('a ticket for another coach says so, and names the passenger', () {
      final outcome = session.scan(demo.tickets['WRONG_DEPARTURE']!);

      expect(outcome.result, VerificationResult.wrongDeparture);
      // The conductor has to be able to redirect them, so the payload must
      // survive the rejection.
      expect(outcome.payload!.passengerName, 'Denis Bouiti');
      expect(outcome.expectedDepartureId, DemoDeparture.departureId);
      expect(session.boardedCount, 0);
    });

    test('a refunded ticket does not board', () {
      // Voided at refund APPROVAL, so it cannot board while the money is
      // still in flight.
      final outcome = session.scan(
        ticket('T5W2YZ', '3A'),
        presentedCode: liveCode('T5W2YZ', '3A'),
      );
      expect(outcome.result, VerificationResult.voided);
      expect(session.boardedCount, 0);
    });

    test('a screenshot scans but its code is stale', () {
      final frozen = liveCode(
        'ZZ1188',
        '2C',
        now.subtract(const Duration(minutes: 10)),
      );
      final outcome = session.scan(
        ticket('ZZ1188', '2C'),
        presentedCode: frozen,
      );

      expect(outcome.result, VerificationResult.staleCode);
      expect(session.boardedCount, 0);
    });

    test('a tampered ticket is invalid', () {
      final forged = ticket('ZZ1188', '2C').replaceFirst('2C', '1A');
      expect(session.scan(forged).result, VerificationResult.invalid);
    });

    test('unreadable input is invalid, not a crash', () {
      // A conductor will scan a bottle label at some point.
      for (final junk in ['', 'https://example.com', 'ZZZZ']) {
        expect(session.scan(junk).result, VerificationResult.invalid);
      }
    });
  });

  group('the stale-code override', () {
    test('boards the passenger and records why', () {
      final frozen = liveCode(
        'ZZ1188',
        '2C',
        now.subtract(const Duration(minutes: 10)),
      );
      final stale = session.scan(ticket('ZZ1188', '2C'), presentedCode: frozen);
      expect(stale.result, VerificationResult.staleCode);

      // Refusing a real passenger over a slow phone is the worse outcome, so
      // the conductor can override — and it is logged for review.
      final overridden = session.overrideStaleCode(stale);

      expect(overridden.result, VerificationResult.valid);
      expect(overridden.detail, 'override');
      expect(session.boardedCount, 1);
      expect(session.boarded.single.codeWasStale, isTrue);
    });

    test('cannot be used to force any other verdict', () {
      // An override is not a skeleton key. A refunded or forged ticket stays
      // refused.
      final voided = session.scan(
        ticket('T5W2YZ', '3A'),
        presentedCode: liveCode('T5W2YZ', '3A'),
      );
      expect(
        session.overrideStaleCode(voided).result,
        VerificationResult.voided,
      );
      expect(session.boardedCount, 0);
    });
  });

  group('manual boarding — a dead phone must still travel', () {
    test('boards by reference and flags it manual', () {
      final outcome = session.boardManually(
        bookingRef: 'H4T9RB',
        seatLabel: '5A',
      );

      expect(outcome.result, VerificationResult.valid);
      expect(session.boardedCount, 1);
      expect(session.boarded.single.manual, isTrue);
      expect(session.boarded.single.passengerName, 'Jean-Marc Obami');
    });

    test('still refuses a refunded ticket', () {
      expect(
        session.boardManually(bookingRef: 'T5W2YZ', seatLabel: '3A').result,
        VerificationResult.voided,
      );
    });

    test('still catches a double boarding', () {
      session.boardManually(bookingRef: 'H4T9RB', seatLabel: '5A');
      expect(
        session.boardManually(bookingRef: 'H4T9RB', seatLabel: '5A').result,
        VerificationResult.alreadyBoarded,
      );
    });

    test('search finds a passenger by name, reference or seat', () {
      expect(session.search('aline').single.seatLabel, '14A');
      expect(session.search('H4T9RB'), hasLength(2));
      expect(session.search('9d').single.passengerName, 'Antoine Bikindou');
      expect(session.search('nobody'), isEmpty);
    });
  });

  group('who is missing', () {
    test('no-shows shrink as people board', () {
      expect(session.noShows, hasLength(8));

      session.scan(
        ticket('7QK4M2', '14A'),
        presentedCode: liveCode('7QK4M2', '14A'),
      );
      expect(session.noShows, hasLength(7));
      expect(session.noShows.map((e) => e.seatLabel), isNot(contains('14A')));
    });

    test('a full coach reports complete', () {
      for (final entry in demo.manifest.entries.values) {
        session.boardManually(
          bookingRef: entry.bookingRef,
          seatLabel: entry.seatLabel,
        );
      }
      // The refunded seat can never board, so a coach with a refund never
      // reaches 8/8 — which is correct, and the conductor should see it.
      expect(session.boardedCount, 7);
      expect(session.isComplete, isFalse);
      expect(session.noShows.single.seatLabel, '3A');
    });
  });

  group('the door knows where they get off', () {
    test('a leg rides on the verdict, a whole road does not', () {
      // Marie bought Brazzaville→Dolisie. The conductor scanning her at the
      // door is the person who has to know 2C comes free three hours from
      // now, and the only place that fact reaches them is here — the QR is
      // signed and says nothing about it.
      final leg = session.scan(
        ticket('ZZ1188', '2C'),
        presentedCode: liveCode('ZZ1188', '2C'),
      );
      expect(leg.result, VerificationResult.valid);
      expect(leg.entry!.boardsAt, 'BZV');
      expect(leg.entry!.alightsAt, 'DOL');

      // Aline is riding the whole road, which is what the departure already
      // says. Nothing extra goes on her verdict.
      final whole = session.scan(
        ticket('7QK4M2', '14A'),
        presentedCode: liveCode('7QK4M2', '14A'),
      );
      expect(whole.entry!.alightsAt, isNull);
    });

    test('a dead phone boarded by hand carries it too', () {
      // The manual path is the one used at the roadside with a flat battery,
      // and it reads the same row.
      final outcome = session.boardManually(
        bookingRef: 'K2M8PQ',
        seatLabel: '9D',
      );
      expect(outcome.result, VerificationResult.valid);
      expect(outcome.entry!.boardsAt, 'DOL');
    });

    test('a second scan still names the leg', () {
      final code = liveCode('ZZ1188', '2C');
      session.scan(ticket('ZZ1188', '2C'), presentedCode: code);
      final again = session.scan(ticket('ZZ1188', '2C'), presentedCode: code);

      // The verdict a conductor argues with is the refusal, so it has to
      // carry as much as the acceptance did.
      expect(again.result, VerificationResult.alreadyBoarded);
      expect(again.entry!.alightsAt, 'DOL');
    });
  });

  group('offline behaviour', () {
    test('a whole boarding run touches no network', () {
      // The session holds a manifest, a verifier and a local log. There is no
      // client, no socket, no future. That is the roadside guarantee.
      for (final ref in [
        ('7QK4M2', '14A'),
        ('7QK4M2', '14B'),
        ('ZZ1188', '2C'),
        ('H4T9RB', '5A'),
        ('H4T9RB', '5B'),
        ('K2M8PQ', '9D'),
        ('R7V3XN', '11C'),
      ]) {
        final outcome = session.scan(
          ticket(ref.$1, ref.$2),
          presentedCode: liveCode(ref.$1, ref.$2),
        );
        expect(outcome.boards, isTrue, reason: '${ref.$1}/${ref.$2}');
      }

      expect(session.boardedCount, 7);
      expect(session.progress, '7 / 8');
    });

    test('redemptions queue for sync rather than blocking the door', () {
      session.scan(
        ticket('7QK4M2', '14A'),
        presentedCode: liveCode('7QK4M2', '14A'),
      );

      final pending = log.pending();
      expect(pending, hasLength(1));
      expect(pending.single['mode'], 'scan');

      log.markSynced([BoardingManifest.keyFor('7QK4M2', '14A')]);
      expect(log.pending(), isEmpty);
    });
  });

  group('the demo departure is genuinely signed', () {
    test('tickets verify through the real Ed25519 path', () {
      // A demo that fakes its own verdict proves nothing. These are real
      // signatures checked by the real verifier.
      final outcome = session.scan(
        ticket('K2M8PQ', '9D'),
        presentedCode: liveCode('K2M8PQ', '9D'),
      );
      expect(outcome.result, VerificationResult.valid);
    });

    test('every ticket fits the QR density budget', () {
      for (final entry in demo.tickets.entries) {
        expect(
          entry.value.length,
          lessThanOrEqualTo(TicketPayload.maxEncodedBytes),
          reason: entry.key,
        );
      }
    });
  });
}
