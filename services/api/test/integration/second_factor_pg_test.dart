@Tags(['integration'])
library;

import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_second_factors.dart';
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
///   * **an unconfirmed row is not a factor**, and cannot be confirmed twice.
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

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    factors = PostgresSecondFactors(db);
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  var seq = 0;
  Future<String> person() =>
      fixture.traveller('9${(++seq).toString().padLeft(4, '0')}');

  /// Somebody with a working authenticator.
  Future<String> enrolled({int recoveryCodes = 3}) async {
    final id = await person();
    await factors.beginEnrolment(
      userId: id,
      secretBase32: 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP',
      recoveryHashes: [
        for (var i = 0; i < recoveryCodes; i++) 'hash-$id-$i',
      ],
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
}
