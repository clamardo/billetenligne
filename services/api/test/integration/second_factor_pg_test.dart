@Tags(['integration'])
library;

import 'dart:io';

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_second_factors.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// The second factor, against the database that enforces it.
///
/// The memory adapter reproduces these refusals, and that is exactly why they
/// have to be proved here too: a fake agreeing with itself proves nothing
/// about the SQL, and every one of these is a control rather than a
/// convenience.
///
///   * **a window is spent conditionally**, in one statement, so two requests
///     carrying the same six digits at the same instant produce one sign-in.
///     Read-then-write in Dart would let both through;
///   * **a recovery code burns once**, by the same mechanism;
///   * **the lock counts on the factor**, so discarding a half-session and
///     asking for another does not refill the guess budget;
///   * **an unconfirmed row is not a factor**, and cannot be confirmed twice;
///   * **the seed on disk is not the seed the app holds**, and a row written
///     before the key existed is upgraded by being read.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresSecondFactors factors;
  late Connection raw;

  // The shape the environment carries. Thirty-two characters, hashed to a key
  // — see `SecretCipher.fromPassphrase`.
  final cipher = SecretCipher.fromPassphrase(
    'integration-only-totp-key-32-chars',
  )!;

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    factors = PostgresSecondFactors(db, cipher: cipher);
    // A second connection, outside the adapter, so a test can look at the
    // bytes rather than at what the adapter says about them. That is the only
    // way to prove a seed is sealed: the adapter hands back plaintext either
    // way, which is exactly its job.
    raw = await Connection.open(
      _seedEndpoint(Platform.environment['SEED_DATABASE_URL']!),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    await raw.close();
    await db.close();
    await fixture.close();
  });

  Future<String> storedSeed(String userId) async {
    final rows = await raw.execute(
      Sql.named('SELECT secret FROM user_totp WHERE user_id = @id'),
      parameters: {'id': TypedValue(Type.uuid, userId)},
    );
    return rows.first.toColumnMap()['secret'] as String;
  }

  var seq = 0;
  Future<String> person() =>
      fixture.traveller('9${(++seq).toString().padLeft(4, '0')}');

  /// Somebody with a working authenticator.
  Future<String> enrolled({int recoveryCodes = 3}) async {
    final id = await person();
    await factors.beginEnrolment(
      userId: id,
      secretBase32: 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
      recoveryHashes: [for (var i = 0; i < recoveryCodes; i++) 'hash-$id-$i'],
    );
    await factors.confirm(userId: id, window: 1000);
    return id;
  }

  group('enrolment', () {
    test('an unconfirmed row is not a factor', () async {
      final id = await person();
      await factors.beginEnrolment(
        userId: id,
        secretBase32: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        recoveryHashes: const ['h1'],
      );

      final factor = await factors.forUser(id);
      expect(factor, isNotNull);
      expect(factor!.isConfirmed, isFalse);
      expect(factor.unusedRecoveryCodes, 1);
    });

    test('restarting replaces the secret and the codes', () async {
      final id = await person();
      await factors.beginEnrolment(
        userId: id,
        secretBase32: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        recoveryHashes: const ['h1'],
      );
      await factors.beginEnrolment(
        userId: id,
        secretBase32: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
        recoveryHashes: const ['h2', 'h3'],
      );

      final factor = (await factors.forUser(id))!;
      expect(factor.secretBase32, 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB');
      expect(factor.unusedRecoveryCodes, 2);
      // The old code is gone, not merely unusable.
      expect(
        await factors.spendRecoveryCode(userId: id, codeHash: 'h1'),
        isFalse,
      );
    });

    test('a confirmed factor is never silently replaced', () async {
      final id = await enrolled();
      final again = await factors.beginEnrolment(
        userId: id,
        secretBase32: 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
        recoveryHashes: const ['h9'],
      );

      expect(again, isNull);
      expect((await factors.forUser(id))!.secretBase32, isNot(startsWith('C')));
    });

    test('a replayed confirmation confirms nothing twice', () async {
      final id = await enrolled();
      expect(await factors.confirm(userId: id, window: 2000), isFalse);
      // And it did not move the replay pointer either.
      expect(await factors.spendWindow(userId: id, window: 1001), isTrue);
    });
  });

  group('spending a window', () {
    test('the same window cannot be spent twice', () async {
      final id = await enrolled();
      expect(await factors.spendWindow(userId: id, window: 1001), isTrue);
      expect(await factors.spendWindow(userId: id, window: 1001), isFalse);
    });

    test('an older window is refused', () async {
      final id = await enrolled();
      await factors.spendWindow(userId: id, window: 1005);
      expect(await factors.spendWindow(userId: id, window: 1004), isFalse);
    });

    // The control the whole design rests on. Two requests carrying the same
    // six digits, in flight together: one wins, in the database.
    test('two simultaneous attempts produce one sign-in', () async {
      final id = await enrolled();
      final outcomes = await Future.wait([
        factors.spendWindow(userId: id, window: 1010),
        factors.spendWindow(userId: id, window: 1010),
        factors.spendWindow(userId: id, window: 1010),
      ]);

      expect(outcomes.where((won) => won), hasLength(1));
    });

    test('an unconfirmed factor cannot spend anything', () async {
      final id = await person();
      await factors.beginEnrolment(
        userId: id,
        secretBase32: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        recoveryHashes: const ['h1'],
      );
      expect(await factors.spendWindow(userId: id, window: 5), isFalse);
    });
  });

  group('recovery codes', () {
    test('one burns once', () async {
      final id = await enrolled();
      expect(
        await factors.spendRecoveryCode(userId: id, codeHash: 'hash-$id-0'),
        isTrue,
      );
      expect(
        await factors.spendRecoveryCode(userId: id, codeHash: 'hash-$id-0'),
        isFalse,
      );
      expect((await factors.forUser(id))!.unusedRecoveryCodes, 2);
    });

    test('two simultaneous uses of one code burn it once', () async {
      final id = await enrolled();
      final outcomes = await Future.wait([
        factors.spendRecoveryCode(userId: id, codeHash: 'hash-$id-1'),
        factors.spendRecoveryCode(userId: id, codeHash: 'hash-$id-1'),
      ]);

      expect(outcomes.where((won) => won), hasLength(1));
    });

    test("a stranger's code is not mine to spend", () async {
      final mine = await enrolled();
      final theirs = await enrolled();
      expect(
        await factors.spendRecoveryCode(
          userId: mine,
          codeHash: 'hash-$theirs-0',
        ),
        isFalse,
      );
    });
  });

  group('the lock', () {
    test('counts on the factor and lifts on a success', () async {
      final id = await enrolled();

      for (var i = 1; i <= 4; i++) {
        final after = await factors.recordFailure(
          userId: id,
          lockAfter: 5,
          lockFor: const Duration(minutes: 15),
        );
        expect(after!.failedAttempts, i);
        expect(after.lockedUntil, isNull);
      }

      final locked = await factors.recordFailure(
        userId: id,
        lockAfter: 5,
        lockFor: const Duration(minutes: 15),
      );
      expect(locked!.lockedUntil, isNotNull);
      expect(locked.isLockedAt(DateTime.now().toUtc()), isTrue);

      // A correct code clears both the count and the lock: the budget is for
      // consecutive failures, not for a lifetime.
      await factors.spendWindow(userId: id, window: 2000);
      final cleared = (await factors.forUser(id))!;
      expect(cleared.failedAttempts, 0);
      expect(cleared.lockedUntil, isNull);
    });

    test('a recovery code clears it too', () async {
      final id = await enrolled();
      for (var i = 0; i < 5; i++) {
        await factors.recordFailure(
          userId: id,
          lockAfter: 5,
          lockFor: const Duration(minutes: 15),
        );
      }

      await factors.spendRecoveryCode(userId: id, codeHash: 'hash-$id-2');
      final cleared = (await factors.forUser(id))!;
      expect(cleared.failedAttempts, 0);
      expect(cleared.lockedUntil, isNull);
    });
  });

  test('disabling removes the factor but keeps the burned codes', () async {
    final id = await enrolled();
    await factors.spendRecoveryCode(userId: id, codeHash: 'hash-$id-0');
    await factors.disable(id);

    expect(await factors.forUser(id), isNull);

    // A burned code is evidence of the incident it was burned during, so it
    // outlives the factor. Re-enrolling starts a fresh list rather than
    // resurrecting the old one.
    await factors.beginEnrolment(
      userId: id,
      secretBase32: 'DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
      recoveryHashes: const ['fresh-1'],
    );
    expect((await factors.forUser(id))!.unusedRecoveryCodes, 1);
  });

  group('the seed at rest', () {
    const seed = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';

    test('what is written is not what was scanned', () async {
      final id = await enrolled();

      final stored = await storedSeed(id);
      expect(stored, startsWith('v1.'));
      // The literal check, not just the prefix. A format that carried the
      // plaintext alongside a ciphertext would pass every other assertion
      // here.
      expect(stored, isNot(contains(seed)));

      // And the adapter still hands back the thing an authenticator computes
      // from. If this broke, every member of staff would be locked out and no
      // other test in this file would notice.
      expect((await factors.forUser(id))!.secretBase32, seed);
    });

    test('a row from before the key is upgraded by being read', () async {
      // Exactly the state a deploy lands in: rows written by the adapter as
      // it was yesterday.
      final plain = PostgresSecondFactors(db);
      final id = await person();
      await plain.beginEnrolment(
        userId: id,
        secretBase32: seed,
        recoveryHashes: const [],
      );
      expect(await storedSeed(id), seed);

      // One read through the sealed adapter, and it is gone from the table —
      // without the person noticing, and without the value changing.
      expect((await factors.forUser(id))!.secretBase32, seed);
      expect(await storedSeed(id), startsWith('v1.'));
      expect((await factors.forUser(id))!.secretBase32, seed);
    });

    test(
      'a sealed row with no key is an error, not a missing factor',
      () async {
        final id = await enrolled();
        final blind = PostgresSecondFactors(db);

        // The failure mode this refuses: a factor that reads as absent is a
        // factor an attacker can enrol again. Losing the key must be an outage.
        expect(blind.forUser(id), throwsA(isA<StateError>()));
      },
    );

    test('the wrong key is refused rather than answered wrongly', () async {
      final id = await enrolled();
      final other = PostgresSecondFactors(
        db,
        cipher: SecretCipher.fromPassphrase(
          'a-completely-different-key-of-32ch',
        ),
      );

      expect(other.forUser(id), throwsA(isA<Object>()));
    });
  });
}

/// The seeding connection, parsed the same way `PgFixture` parses it.
///
/// A second connection *outside* the adapter, because proving a seed is sealed
/// means looking at the bytes: the adapter hands back plaintext either way,
/// which is precisely its job.
Endpoint _seedEndpoint(String url) {
  final uri = Uri.parse(url);
  final auth = uri.userInfo.split(':');
  return Endpoint(
    host: uri.host,
    port: uri.port == 0 ? 5432 : uri.port,
    database: uri.pathSegments.first,
    username: auth.first,
    password: auth.length > 1 ? auth[1] : null,
  );
}
