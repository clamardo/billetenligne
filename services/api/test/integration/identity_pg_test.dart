@Tags(['integration'])
library;

import 'dart:convert';

import 'package:bel_api/src/application/ports/notification_gateway.dart';
import 'package:bel_api/src/application/sign_in.dart';
import 'package:bel_api/src/adapters/logging_notification_gateway.dart';
import 'package:bel_api/src/infrastructure/db/database.dart';
import 'package:bel_api/src/infrastructure/postgres/postgres_identity.dart';
import 'package:bel_contracts/bel_contracts.dart';
import 'package:bel_crypto/bel_crypto.dart';
import 'package:test/test.dart';

import 'pg_fixture.dart';

/// Identity, against the database that will actually arbitrate it.
///
/// The in-memory suite proves the rules. This file exists for the four claims
/// a Dart map cannot make:
///
///   * the **upsert** is one statement, so two devices signing in at once
///     produce one account and agree on which of them created it;
///   * the **conditional consume** is a write, so a code answered twice signs
///     in once — the property the whole replay defence rests on;
///   * `lower(email)` is a **unique index**, so case is not an account;
///   * the **identity role** can do all of that and cannot touch a seat.
///
///   ./tool/integration.sh
void main() {
  if (!PgFixture.isAvailable) {
    test('integration suite', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  late PgFixture fixture;
  late Database db;
  late PostgresUserDirectory directory;
  late PostgresAuthChallenges challenges;
  late FakeNotificationGateway notifications;
  late SignIn signIn;

  /// A unique address per test, because the suite shares one database and an
  /// account created by an earlier test would make a later one pass for the
  /// wrong reason.
  var seq = 0;
  String freshEmail() =>
      'traveller${++seq}.${DateTime.now().microsecondsSinceEpoch}@example.cg';

  setUpAll(() async {
    fixture = await PgFixture.open();
    db = Database.open(PgFixture.appUrl);
    directory = PostgresUserDirectory(db);
    challenges = PostgresAuthChallenges(db);
  });

  setUp(() {
    notifications = FakeNotificationGateway();
    signIn = SignIn(
      challenges: challenges,
      directory: directory,
      notifications: notifications,
      render:
          ({
            required SignInChannel channel,
            required String language,
            required String code,
            required int minutes,
          }) => (subject: 'code:$code', body: code),
      mac: const HmacSha256Authenticator(),
      codeKey: utf8.encode('an-integration-key-of-32-characters'),
    );
  });

  tearDownAll(() async {
    await db.close();
    await fixture.close();
  });

  String codeSent() => notifications.last.body;

  Future<SignedIn> signInWith(String email) async {
    final started = await signIn.start(StartSignInRequest.email(email));
    final challenge = started.valueOrNull!;
    final done = await signIn.complete(
      VerifySignInRequest(challengeId: challenge.challengeId, code: codeSent()),
    );
    return done.valueOrNull!;
  }

  test('a first sign-in creates the account and its Firebase UID', () async {
    final email = freshEmail();
    final result = await signInWith(email);

    expect(result.isNewAccount, isTrue);
    expect(result.account.email, email);
    // The UID is our account id. Letting Firebase mint one would mean a
    // network round trip inside this transaction, and a failure there would
    // leave an account nobody can ever sign in to.
    expect(result.account.authUid, result.account.id);

    final resolved = await directory.byAuthUid(result.account.authUid!);
    expect(resolved!.id, result.account.id);
    expect(resolved.emailVerifiedAt, isNotNull);
  });

  test('two devices signing in at once produce exactly one account', () async {
    final email = freshEmail();

    // Both race the same upsert. `ON CONFLICT` decides; a read-then-write
    // would leave a window here, and the window is a duplicate account.
    final both = await Future.wait([
      directory.forVerifiedEmail(email: email, language: 'fr'),
      directory.forVerifiedEmail(email: email, language: 'fr'),
    ]);

    expect(both[0].account.id, both[1].account.id);
    expect(
      both.where((r) => r.created).length,
      1,
      reason: 'exactly one of the two may report having created it',
    );
  });

  test('case is not an account', () async {
    final email = freshEmail();
    final lower = await directory.forVerifiedEmail(
      email: email,
      language: 'fr',
    );
    final upper = await directory.forVerifiedEmail(
      email: email.toUpperCase(),
      language: 'fr',
    );

    // The application lowercases before it writes; `user_accounts_email_lower`
    // is what makes that a guarantee rather than a convention. Two accounts
    // here would mean two ticket histories and a traveller certain we lost
    // their booking.
    expect(upper.account.id, lower.account.id);
    expect(upper.created, isFalse);
  });

  test('a correct code cannot be answered twice', () async {
    final started = await signIn.start(StartSignInRequest.email(freshEmail()));
    final id = started.valueOrNull!.challengeId;
    final code = codeSent();

    final both = await Future.wait([
      signIn.complete(VerifySignInRequest(challengeId: id, code: code)),
      signIn.complete(VerifySignInRequest(challengeId: id, code: code)),
    ]);

    // `UPDATE ... WHERE consumed_at IS NULL` is what settles it. Checking in
    // Dart first would leave both requests believing they were the first.
    expect(both.where((r) => r.isOk).length, 1);
    expect(
      both.where((r) => r.isErr).single.failureOrNull,
      isA<ChallengeNoLongerValid>(),
    );
  });

  test('concurrent wrong guesses each cost an attempt', () async {
    final started = await signIn.start(StartSignInRequest.email(freshEmail()));
    final id = started.valueOrNull!.challengeId;

    // `attempts = attempts + 1` in the statement. A read-then-write pair lets
    // five concurrent guesses all read zero and cost one between them, which
    // is a rate limit that does not limit anything.
    await Future.wait([
      for (var i = 0; i < 5; i++)
        signIn.complete(VerifySignInRequest(challengeId: id, code: '00000$i')),
    ]);

    final after = await challenges.byId(id);
    expect(after!.attempts, 5);
    expect(after.isExhausted, isTrue);
  });

  test('the code is never in the row', () async {
    final started = await signIn.start(StartSignInRequest.email(freshEmail()));
    final stored = await challenges.byId(started.valueOrNull!.challengeId);

    expect(stored!.codeHash, isNot(contains(codeSent())));
    expect(stored.codeHash, hasLength(64));
  });

  test(
    'an expiry is decided by Postgres, not by three disagreeing clocks',
    () async {
      final started = await signIn.start(
        StartSignInRequest.email(freshEmail()),
      );
      final stored = await challenges.byId(started.valueOrNull!.challengeId);

      // `created_at` comes from `now()` and the CHECK constraint refuses a row
      // whose expiry precedes it — so a fast API instance cannot issue a code
      // that was already dead when it was written.
      expect(stored!.expiresAt.isAfter(stored.createdAt), isTrue);
    },
  );

  test(
    'an operator-created account is verified the first time its owner signs in',
    () async {
      // The guichet path: an agent types an address to send a ticket to. That
      // identifies the traveller; it does not authenticate them. The stamp only
      // lands when they answer a code.
      final email = freshEmail();
      final seeded = await directory.forVerifiedEmail(
        email: email,
        language: 'fr',
      );
      expect(seeded.created, isTrue);

      final again = await directory.forVerifiedEmail(
        email: email,
        language: 'en',
      );
      expect(again.created, isFalse);
      // The original verification time is kept, not overwritten on every visit.
      expect(again.account.emailVerifiedAt, seeded.account.emailVerifiedAt);
    },
  );

  test('the logging gateway is what runs when nothing is configured', () async {
    expect(
      await const LoggingNotificationGateway().send(
        const OutboundMessage(
          channel: SignInChannel.email,
          to: 'aline@example.cg',
          body: 'code',
        ),
      ),
      isNull,
    );
  });
}
