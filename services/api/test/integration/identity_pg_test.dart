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
          }) => (
            subject: 'code:$code',
            body: code,
            heading: null,
            highlight: code,
          ),
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

  group('the membership every console request is scoped by', () {
    // This is the read that decides whether somebody is staff, and of whom.
    // It runs on the identity surface, before any tenant is known, which is
    // exactly the constraint that broke it: the lookup joined `operators` to
    // check the status, that surface cannot see `operators`, and RLS filters
    // rather than raising. Membership came back null and every console and
    // back-office request answered 403 to a signed-in org owner.
    //
    // Nothing above caught it, because the API suites build a TenantScope
    // directly and never travel this path. These two tests do.
    test('an org owner resolves to their operator', () async {
      final signedIn = await signInWith(freshEmail());
      final uid = signedIn.account.authUid!;

      // Before the invitation is accepted, this person is a traveller.
      expect((await directory.byAuthUid(uid))!.staff, isNull);

      await fixture.rows("""
        INSERT INTO operator_staff (operator_id, user_id, roles, accepted_at)
        VALUES ('${PgFixture.operatorId}', '${signedIn.account.id}',
                ARRAY['org_owner'], now())
      """);

      final account = await directory.byAuthUid(uid);
      expect(account!.staff, isNotNull);
      expect(account.staff!.operatorId, PgFixture.operatorId);
      expect(account.staff!.roles, contains('org_owner'));
    });

    test('staff of an operator that has stopped trading do not', () async {
      final signedIn = await signInWith(freshEmail());
      final rows = await fixture.rows("""
        INSERT INTO operators (code, legal_name, trading_name, status,
                               market_code)
        VALUES ('SUSP-${DateTime.now().microsecondsSinceEpoch}',
                'Suspendu SARL', 'Suspendu', 'suspended', 'CG')
        RETURNING id
      """);
      final suspended = rows.single['id'];

      await fixture.rows("""
        INSERT INTO operator_staff (operator_id, user_id, roles, accepted_at)
        VALUES ('$suspended', '${signedIn.account.id}',
                ARRAY['org_owner'], now())
      """);

      // Not an error and not a scope: a suspension is a decision about the
      // company, and the person holding the token learns nothing about it
      // here beyond having no console to open.
      expect(
        (await directory.byAuthUid(signedIn.account.authUid!))!.staff,
        isNull,
      );
    });
  });

  group('a custom role\'s capabilities travel with the membership', () {
    // The whole reason `TenantScope.forPrincipal` stays pure and synchronous
    // is that this join already read the custom role fresh — so this is the
    // one place the feature can be cosmetic without a single unit test
    // noticing: a Dart map cannot prove `operator_custom_roles` was actually
    // joined, only a query against it can.
    test(
      'resolves to the capabilities stored under the role\'s name',
      () async {
        final signedIn = await signInWith(freshEmail());
        final uid = signedIn.account.authUid!;

        final roleRows = await fixture.rows("""
        INSERT INTO operator_custom_roles (operator_id, name, capabilities)
        VALUES ('${PgFixture.operatorId}', 'ticket_seller_id_${DateTime.now().microsecondsSinceEpoch}',
                ARRAY['booking.read', 'booking.sell'])
        RETURNING name
      """);
        final roleName = roleRows.single['name'] as String;

        await fixture.rows("""
        INSERT INTO operator_staff (operator_id, user_id, roles, accepted_at)
        VALUES ('${PgFixture.operatorId}', '${signedIn.account.id}',
                ARRAY['$roleName'], now())
      """);

        final account = await directory.byAuthUid(uid);
        expect(account!.staff!.roles, contains(roleName));
        expect(
          account.staff!.customRoleCapabilities[roleName],
          unorderedEquals(['booking.read', 'booking.sell']),
        );
      },
    );

    test(
      'a role name nobody defined resolves to no extra capabilities',
      () async {
        final signedIn = await signInWith(freshEmail());
        await fixture.rows("""
        INSERT INTO operator_staff (operator_id, user_id, roles, accepted_at)
        VALUES ('${PgFixture.operatorId}', '${signedIn.account.id}',
                ARRAY['a_role_nobody_defined'], now())
      """);

        final account = await directory.byAuthUid(signedIn.account.authUid!);
        expect(account!.staff!.customRoleCapabilities, isEmpty);
      },
    );

    test(
      'a role by the same name at a different operator grants nothing here',
      () async {
        final signedIn = await signInWith(freshEmail());
        final otherRows = await fixture.rows("""
          INSERT INTO operators (code, legal_name, trading_name, status,
                                 market_code)
          VALUES ('OTH-${DateTime.now().microsecondsSinceEpoch}',
                  'Autre SARL', 'Autre', 'active', 'CG')
          RETURNING id
        """);
        final otherOperatorId = otherRows.single['id'];

        await fixture.rows("""
          INSERT INTO operator_custom_roles (operator_id, name, capabilities)
          VALUES ('$otherOperatorId', 'shared_name', ARRAY['staff.manage'])
        """);
        await fixture.rows("""
          INSERT INTO operator_staff (operator_id, user_id, roles, accepted_at)
          VALUES ('${PgFixture.operatorId}', '${signedIn.account.id}',
                  ARRAY['shared_name'], now())
        """);

        final account = await directory.byAuthUid(signedIn.account.authUid!);
        expect(account!.staff!.customRoleCapabilities, isEmpty);
      },
    );
  });

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

      // And the language is NOT overwritten by a later sign-in either — which
      // is exactly why `setLanguage` had to exist. Signing in on a borrowed
      // English handset must not silently rewrite what somebody reads.
      expect(again.account.language, 'fr');
    },
  );

  test(
    'signing in resolves who somebody is, not only that they exist',
    () async {
      // **The regression this exists for.** `forVerifiedEmail` is an upsert,
      // and a `RETURNING` clause cannot see a LATERAL join — so the account
      // it handed back carried `staff: null` and `platformRole: null` for
      // everybody, an operator's owner and our own administrators included.
      // `SecondFactorSignIn.isRequiredFor` reads exactly those two fields.
      // The result was that ADR-0013's mandatory second factor on both
      // back-office surfaces was never once asked for, on any sign-in, and
      // nothing on screen said so: the console simply opened.
      //
      // Every other caller reads the joined query, so nothing but a sign-in
      // was ever wrong — which is why no console test caught it.
      final userId = await fixture.staffMember(
        roles: const ['org_owner'],
        suffix: '7742',
        name: 'Angele Mbemba',
      );
      final email = freshEmail();
      await fixture.rows(
        "UPDATE user_accounts SET email = '$email' WHERE id = '$userId'",
      );

      final signedIn = await directory.forVerifiedEmail(
        email: email,
        language: 'fr',
      );

      expect(signedIn.account.id, userId);
      expect(signedIn.account.staff, isNotNull);
      expect(signedIn.account.staff!.roles, contains('org_owner'));

      // And it agrees with the query every request after sign-in uses. Two
      // shapes of the same person is how this diverged in the first place.
      final later = await directory.byId(userId);
      expect(later!.staff!.operatorId, signedIn.account.staff!.operatorId);
    },
  );

  test('our own people are resolved as staff on sign-in too', () async {
    // The platform half of the same bug. A `super_admin` who signed in was
    // handed an account with no platform role, so the back office asked them
    // for nothing either.
    final email = freshEmail();
    final seeded = await directory.forVerifiedEmail(
      email: email,
      language: 'fr',
    );
    await fixture.rows(
      'INSERT INTO platform_staff (user_id, role) '
      "VALUES ('${seeded.account.id}', 'operations') "
      'ON CONFLICT (user_id) DO UPDATE SET role = EXCLUDED.role, '
      'revoked_at = NULL',
    );

    final again = await directory.forVerifiedEmail(
      email: email,
      language: 'fr',
    );

    expect(again.account.platformRole, 'operations');
    expect(again.account.isPlatformStaff, isTrue);
  });

  test(
    'the language on an account can be changed, and only to a real one',
    () async {
      final email = freshEmail();
      final seeded = await directory.forVerifiedEmail(
        email: email,
        language: 'fr',
      );

      expect(
        await directory.setLanguage(userId: seeded.account.id, language: 'en'),
        isTrue,
      );

      final after = await directory.byId(seeded.account.id);
      expect(after!.language, 'en');

      // A row for an account that is not there is not an error worth throwing —
      // the caller turns it into the same 401 every other vanished account gets.
      expect(
        await directory.setLanguage(
          userId: '00000000-0000-0000-0000-000000000000',
          language: 'en',
        ),
        isFalse,
      );
    },
  );

  test(
    'one host asking for a thousand codes is counted, and stopped',
    () async {
      // A source unique to this test: the suite shares a database, and a
      // counter that saw another test's requests would pass for the wrong
      // reason — or fail for one.
      final source = 'source-${DateTime.now().microsecondsSinceEpoch}';

      final bounded = SignIn(
        challenges: challenges,
        directory: directory,
        notifications: notifications,
        render:
            ({
              required SignInChannel channel,
              required String language,
              required String code,
              required int minutes,
            }) => (
              subject: 'code:$code',
              body: code,
              heading: null,
              highlight: code,
            ),
        mac: const HmacSha256Authenticator(),
        codeKey: utf8.encode('an-integration-key-of-32-characters'),
        maxPerSource: 3,
      );

      for (var i = 0; i < 3; i++) {
        final sent = await bounded.start(
          StartSignInRequest.email(freshEmail()),
          source: source,
        );
        expect(sent.isOk, isTrue, reason: 'code $i');
      }

      final refused = await bounded.start(
        StartSignInRequest.email(freshEmail()),
        source: source,
      );

      // Every one of those went to a different address, so the per-destination
      // cooldown never fired once. This is the check that sees the pattern.
      expect(refused.failureOrNull, isA<TooManyFromOneSource>());
      expect(notifications.sent, hasLength(3));

      // And the address itself is not in the table — only an HMAC of it, so
      // this is not a log of who asked for a code from where.
      expect(await fixture.challengeSources(source), 0);
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
