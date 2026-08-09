import 'package:bel_api/src/adapters/memory_idempotency_store.dart';
import 'package:bel_api/src/middleware/idempotency.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:test/test.dart';

void main() {
  late MemoryIdempotencyStore store;
  late Idempotency idem;

  setUp(() {
    store = MemoryIdempotencyStore();
    idem = Idempotency(store);
  });

  const payBody = {'holdId': 'h1', 'railId': 'cg.airtel_money'};

  group('the duplicate-tap guarantee', () {
    test('a fresh key proceeds', () async {
      final outcome = await idem.check(
        key: 'k1',
        scope: 'payments',
        body: payBody,
      );
      expect(outcome, isA<ProceedFresh>());
    });

    test('a completed key replays the original response verbatim', () async {
      await idem.check(key: 'k1', scope: 'payments', body: payBody);
      await idem.record('k1', 201, {'id': 'pi_1', 'state': 'pending'});

      final again = await idem.check(
        key: 'k1',
        scope: 'payments',
        body: payBody,
      );

      expect(again, isA<ReplayStored>());
      final replay = again as ReplayStored;
      expect(replay.statusCode, 201);
      // The SAME intent id. A second charge is the failure this whole
      // mechanism exists to prevent.
      expect(replay.body['id'], 'pi_1');
    });

    test('replaying ten times creates nothing new', () async {
      await idem.check(key: 'k1', scope: 'payments', body: payBody);
      await idem.record('k1', 201, {'id': 'pi_1'});

      for (var i = 0; i < 10; i++) {
        final o = await idem.check(key: 'k1', scope: 'payments', body: payBody);
        expect((o as ReplayStored).body['id'], 'pi_1');
      }
      expect(store.size, 1);
    });

    test(
      'a retry before the first answer is told to wait, not that it failed',
      () async {
        await idem.check(key: 'k1', scope: 'payments', body: payBody);
        final second = await idem.check(
          key: 'k1',
          scope: 'payments',
          body: payBody,
        );

        expect(second, isA<StillInFlight>());
        final err = Idempotency.errorFor(second)!;
        expect(err.code, ErrorCode.conflict);
        expect(
          err.retryable,
          isTrue,
          reason: 'the honest answer is "ask again shortly"',
        );
      },
    );

    test('two concurrent taps race and exactly one proceeds', () async {
      // The real scenario: a slow connection, an impatient thumb.
      final outcomes = await Future.wait([
        for (var i = 0; i < 8; i++)
          idem.check(key: 'k1', scope: 'payments', body: payBody),
      ]);

      expect(outcomes.whereType<ProceedFresh>(), hasLength(1));
      expect(outcomes.whereType<StillInFlight>(), hasLength(7));
    });
  });

  group('a reused key with a different body is a client bug', () {
    test('is rejected rather than silently picking one', () async {
      await idem.check(key: 'k1', scope: 'payments', body: payBody);
      await idem.record('k1', 201, {'id': 'pi_1'});

      final outcome = await idem.check(
        key: 'k1',
        scope: 'payments',
        body: {'holdId': 'h2', 'railId': 'cg.mtn_momo'},
      );

      expect(outcome, isA<KeyReused>());
      expect(
        Idempotency.errorFor(outcome)!.code,
        ErrorCode.idempotencyKeyReused,
      );
    });
  });

  group('body hashing', () {
    test('key order does not matter', () {
      // Clients do not promise key order, and treating a reordered body as a
      // different request would reject legitimate retries.
      expect(
        Idempotency.hashBody({'a': 1, 'b': 2}),
        Idempotency.hashBody({'b': 2, 'a': 1}),
      );
    });

    test('nested key order does not matter either', () {
      expect(
        Idempotency.hashBody({
          'outer': {'x': 1, 'y': 2},
        }),
        Idempotency.hashBody({
          'outer': {'y': 2, 'x': 1},
        }),
      );
    });

    test('a changed value changes the hash', () {
      expect(
        Idempotency.hashBody({'amount': 9300}),
        isNot(Idempotency.hashBody({'amount': 9400})),
      );
    });

    test('list order DOES matter', () {
      // Seat order is meaningful: ["14A","14B"] and ["14B","14A"] may map to
      // different passengers.
      expect(
        Idempotency.hashBody({
          'seats': ['14A', '14B'],
        }),
        isNot(
          Idempotency.hashBody({
            'seats': ['14B', '14A'],
          }),
        ),
      );
    });

    test('a hash is stable across runs', () {
      expect(Idempotency.hashBody(payBody), Idempotency.hashBody(payBody));
      expect(Idempotency.hashBody(payBody), hasLength(16));
    });
  });

  group('a missing key on a money endpoint is refused', () {
    test('null and blank both fail', () async {
      for (final key in [null, '', '   ']) {
        final o = await idem.check(key: key, scope: 'payments', body: payBody);
        expect(o, isA<MissingKey>(), reason: 'key=$key');
        final err = Idempotency.errorFor(o)!;
        expect(err.code, ErrorCode.badRequest);
        expect(err.fieldErrors, contains(BelHeaders.idempotencyKey));
      }
    });

    test('every money-moving route is on the required list', () {
      // Forgetting one endpoint is exactly how a double charge ships.
      expect(Idempotency.isRequired('POST', '/public/v1/payments'), isTrue);
      expect(Idempotency.isRequired('POST', '/public/v1/holds'), isTrue);
      expect(Idempotency.isRequired('POST', '/public/v1/refunds'), isTrue);
      expect(Idempotency.isRequired('POST', '/console/v1/sales'), isTrue);
      // Reads never need one.
      expect(Idempotency.isRequired('GET', '/public/v1/market'), isFalse);
    });
  });

  group('a failed attempt can be genuinely retried', () {
    test('abandoning a claim frees the key', () async {
      await idem.check(key: 'k1', scope: 'payments', body: payBody);
      await idem.abandon('k1');

      final again = await idem.check(
        key: 'k1',
        scope: 'payments',
        body: payBody,
      );
      expect(
        again,
        isA<ProceedFresh>(),
        reason: 'a claim that never produced a response must not block',
      );
    });
  });
}
