import 'package:bel_contracts/bel_contracts.dart';
import 'package:postgres/postgres.dart';

import '../../application/ports/auth_challenges.dart';
import '../../application/ports/user_directory.dart';
import '../db/database.dart';

/// Accounts, on the identity surface.
///
/// Every statement here runs under `DbScope.identity()` — the role from
/// migration 0007 that can read and write exactly `user_accounts` and
/// `auth_challenges` and has no grant on anything that can be sold. That is
/// the whole reason the role exists: resolving a bearer token is a read of
/// `user_accounts` that happens before the request has a surface, a tenant or
/// a user id, so none of the other three roles can perform it.
final class PostgresUserDirectory implements UserDirectory {
  const PostgresUserDirectory(this._db);

  final Database _db;

  static const _columns = '''
    id, auth_uid, email, phone_e164, full_name, language,
    email_verified_at, phone_verified_at, disabled_at
  ''';

  /// Staff membership, read on every authenticated request.
  ///
  /// A LEFT JOIN rather than a second round trip: this runs before every
  /// console request, and an extra query on the hot path of an authenticated
  /// read is a cost paid by everybody to serve the few people who are staff.
  ///
  /// `revoked_at IS NULL` and `accepted_at IS NOT NULL`, so an invitation
  /// nobody accepted grants nothing and a dismissal takes effect on the next
  /// request rather than when a token happens to expire.
  static const _staffJoin = '''
    LEFT JOIN LATERAL (
      SELECT s.operator_id, s.roles, s.station_ids
        FROM operator_staff s
        JOIN operators o ON o.id = s.operator_id
       WHERE s.user_id = user_accounts.id
         AND s.revoked_at IS NULL
         AND s.accepted_at IS NOT NULL
         AND o.status = 'active'
       ORDER BY s.invited_at
       LIMIT 1
    ) staff ON TRUE
  ''';

  /// Our own staff, read on the same request for the same reason.
  ///
  /// A second LATERAL rather than a second round trip. `revoked_at IS NULL`,
  /// so somebody who left this morning is not an administrator this
  /// afternoon — which is the whole argument for reading it per request
  /// instead of trusting a token claim.
  static const _platformJoin = '''
    LEFT JOIN LATERAL (
      SELECT p.role
        FROM platform_staff p
       WHERE p.user_id = user_accounts.id
         AND p.revoked_at IS NULL
       LIMIT 1
    ) platform ON TRUE
  ''';

  @override
  Future<Account?> byAuthUid(String authUid) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT $_columns,
                   staff.operator_id AS staff_operator_id,
                   staff.roles       AS staff_roles,
                   staff.station_ids AS staff_station_ids,
                   platform.role     AS platform_role
              FROM user_accounts $_staffJoin $_platformJoin
             WHERE auth_uid = @uid
          '''),
          parameters: {'uid': TypedValue(Type.text, authUid)},
        );
        return rows.isEmpty ? null : _account(rows.first.toColumnMap());
      });

  @override
  Future<({Account account, bool created})> forVerifiedEmail({
    required String email,
    required String language,
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    // One statement, not a read-then-write. Two people signing in from two
    // devices with the same address at the same moment must produce one
    // account, and only the database can decide which of them created it.
    //
    // `ON CONFLICT (lower(email))` targets the partial unique index from
    // 0007 rather than the plain `email` constraint, because the index is
    // the one that makes `Serge@` and `serge@` the same mailbox.
    //
    // The DO UPDATE is not a no-op dodge: it stamps `email_verified_at` on an
    // account created by some other path — an operator typing an address into
    // the guichet — the first time its owner proves they hold the mailbox.
    //
    // `xmax = 0` is how a single-statement upsert reports which branch it
    // took: Postgres leaves the row's xmax at zero on a genuine insert and
    // sets it to the locking transaction on the update. Obscure, and the only
    // way to learn "was this a new customer?" without a second round trip.
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO user_accounts (email, language, email_verified_at)
        VALUES (@email, @language, now())
        ON CONFLICT (lower(email)) WHERE email IS NOT NULL
        DO UPDATE SET email_verified_at = COALESCE(
                        user_accounts.email_verified_at, now())
        RETURNING $_columns, (xmax = 0) AS created
      '''),
      parameters: {
        'email': TypedValue(Type.text, email),
        'language': TypedValue(Type.text, language),
      },
    );

    return _resolved(tx, rows.first.toColumnMap());
  });

  @override
  Future<({Account account, bool created})> forVerifiedPhone({
    required String phone,
    required String language,
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO user_accounts (phone_e164, language, phone_verified_at)
        VALUES (@phone, @language, now())
        ON CONFLICT (phone_e164)
        DO UPDATE SET phone_verified_at = COALESCE(
                        user_accounts.phone_verified_at, now())
        RETURNING $_columns, (xmax = 0) AS created
      '''),
      parameters: {
        'phone': TypedValue(Type.text, phone),
        'language': TypedValue(Type.text, language),
      },
    );

    return _resolved(tx, rows.first.toColumnMap());
  });

  /// Fills in `auth_uid` the first time we sign somebody in.
  ///
  /// The Firebase UID **is** our account id. Letting Firebase mint one instead
  /// would mean a network round trip inside this transaction, and a failure
  /// there would leave an account nobody can ever sign in to.
  Future<({Account account, bool created})> _resolved(
    TxSession tx,
    Map<String, dynamic> row,
  ) async {
    final created = row['created'] == true;
    var account = _account(row);

    if (account.authUid == null) {
      await tx.execute(
        Sql.named(
          'UPDATE user_accounts SET auth_uid = @uid WHERE id = @id '
          'AND auth_uid IS NULL',
        ),
        parameters: {
          'uid': TypedValue(Type.text, account.id),
          'id': TypedValue(Type.uuid, account.id),
        },
      );
      account = Account(
        id: account.id,
        authUid: account.id,
        email: account.email,
        phone: account.phone,
        fullName: account.fullName,
        language: account.language,
        emailVerifiedAt: account.emailVerifiedAt,
        phoneVerifiedAt: account.phoneVerifiedAt,
        disabledAt: account.disabledAt,
      );
    }

    return (account: account, created: created);
  }

  @override
  Future<Account> forCounterSale({
    required String phone,
    String? fullName,
    String language = 'fr',
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    // No `phone_verified_at`, and that is the whole point. If they already
    // have a verified account this finds it and leaves the stamp alone —
    // a vendor must never be able to mark somebody's number as proved.
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO user_accounts (phone_e164, full_name, language)
        VALUES (@phone, @name, @language)
        ON CONFLICT (phone_e164) DO UPDATE
           SET full_name = COALESCE(user_accounts.full_name, EXCLUDED.full_name)
        RETURNING $_columns
      '''),
      parameters: {
        'phone': TypedValue(Type.text, phone),
        'name': TypedValue(Type.text, fullName),
        'language': TypedValue(Type.text, language),
      },
    );

    var account = _account(rows.first.toColumnMap());

    if (account.authUid == null) {
      await tx.execute(
        Sql.named(
          'UPDATE user_accounts SET auth_uid = @uid WHERE id = @id '
          'AND auth_uid IS NULL',
        ),
        parameters: {
          'uid': TypedValue(Type.text, account.id),
          'id': TypedValue(Type.uuid, account.id),
        },
        ignoreRows: true,
      );
      account = Account(
        id: account.id,
        authUid: account.id,
        email: account.email,
        phone: account.phone,
        fullName: account.fullName,
        language: account.language,
        emailVerifiedAt: account.emailVerifiedAt,
        phoneVerifiedAt: account.phoneVerifiedAt,
        disabledAt: account.disabledAt,
      );
    }

    return account;
  });

  @override
  Future<void> touch(String userId) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        await tx.execute(
          Sql.named('UPDATE user_accounts SET last_seen_at = now() WHERE id = @id'),
          parameters: {'id': TypedValue(Type.uuid, userId)},
          ignoreRows: true,
        );
      });

  static Account _account(Map<String, dynamic> r) => Account(
    staff: r['staff_operator_id'] == null
        ? null
        : StaffMembership(
            operatorId: r['staff_operator_id'].toString(),
            roles: (r['staff_roles'] as List?)?.cast<String>() ?? const [],
            stationIds: [
              for (final id in (r['staff_station_ids'] as List?) ?? const [])
                id.toString(),
            ],
          ),
    id: r['id'].toString(),
    authUid: r['auth_uid'] as String?,
    email: r['email'] as String?,
    phone: r['phone_e164'] as String?,
    fullName: r['full_name'] as String?,
    language: r['language'] as String? ?? 'fr',
    emailVerifiedAt: r['email_verified_at'] as DateTime?,
    phoneVerifiedAt: r['phone_verified_at'] as DateTime?,
    disabledAt: r['disabled_at'] as DateTime?,
    platformRole: r['platform_role'] as String?,
  );
}

/// One-time codes, on the same surface.
///
/// Every time comparison here is made by **Postgres**, never in Dart. Three
/// API instances with three slightly different clocks must not disagree about
/// whether a code has expired — the same reason `HoldSeats` takes no clock.
final class PostgresAuthChallenges implements AuthChallenges {
  const PostgresAuthChallenges(this._db);

  final Database _db;

  static const _columns = '''
    id, channel, destination, code_hash, language, attempts, max_attempts,
    created_at, expires_at, consumed_at
  ''';

  @override
  Future<DateTime?> lastIssuedTo(String destination) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('''
            SELECT created_at FROM auth_challenges
             WHERE destination = @destination
             ORDER BY created_at DESC
             LIMIT 1
          '''),
          parameters: {'destination': TypedValue(Type.text, destination)},
        );
        return rows.isEmpty ? null : rows.first.first as DateTime?;
      });

  @override
  Future<Challenge> issue({
    required SignInChannel channel,
    required String destination,
    required String codeHash,
    required String language,
    required DateTime expiresAt,
    required int maxAttempts,
  }) => _db.transaction(const DbScope.identity(), (tx) async {
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO auth_challenges
          (channel, destination, code_hash, language, expires_at, max_attempts)
        VALUES (@channel, @destination, @hash, @language, @expires, @max)
        RETURNING $_columns
      '''),
      parameters: {
        'channel': TypedValue(Type.text, channel.name),
        'destination': TypedValue(Type.text, destination),
        'hash': TypedValue(Type.text, codeHash),
        'language': TypedValue(Type.text, language),
        'expires': TypedValue(Type.timestampTz, expiresAt),
        'max': TypedValue(Type.integer, maxAttempts),
      },
    );
    return _challenge(rows.first.toColumnMap());
  });

  @override
  Future<Challenge?> byId(String id) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        final rows = await tx.execute(
          Sql.named('SELECT $_columns FROM auth_challenges WHERE id = @id'),
          parameters: {'id': TypedValue(Type.uuid, id)},
        );
        return rows.isEmpty ? null : _challenge(rows.first.toColumnMap());
      });

  @override
  Future<Challenge?> recordFailedAttempt(String id) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        // The increment is the statement, not a read followed by a write.
        // Five concurrent guesses must cost five attempts, and a read-then-
        // write pair would let them all read `0` and cost one.
        final rows = await tx.execute(
          Sql.named('''
            UPDATE auth_challenges
               SET attempts = attempts + 1
             WHERE id = @id AND consumed_at IS NULL
            RETURNING $_columns
          '''),
          parameters: {'id': TypedValue(Type.uuid, id)},
        );
        return rows.isEmpty ? null : _challenge(rows.first.toColumnMap());
      });

  @override
  Future<bool> consume({required String id, required String userId}) =>
      _db.transaction(const DbScope.identity(), (tx) async {
        // `consumed_at IS NULL` and `expires_at > now()` in the WHERE, so a
        // replay of the same correct code and a code answered a millisecond
        // late are both refused *by the write*. Checking either in Dart first
        // would leave a window between the check and the write, and that
        // window is the whole attack.
        final rows = await tx.execute(
          Sql.named('''
            UPDATE auth_challenges
               SET consumed_at = now(), user_id = @user
             WHERE id = @id
               AND consumed_at IS NULL
               AND expires_at > now()
            RETURNING id
          '''),
          parameters: {
            'id': TypedValue(Type.uuid, id),
            'user': TypedValue(Type.uuid, userId),
          },
        );
        return rows.isNotEmpty;
      });

  static Challenge _challenge(Map<String, dynamic> r) => Challenge(
    id: r['id'].toString(),
    channel: SignInChannel.values.firstWhere(
      (c) => c.name == r['channel'],
      orElse: () => SignInChannel.email,
    ),
    destination: r['destination'] as String,
    codeHash: r['code_hash'] as String,
    language: r['language'] as String? ?? 'fr',
    attempts: r['attempts'] as int,
    maxAttempts: r['max_attempts'] as int,
    createdAt: r['created_at'] as DateTime,
    expiresAt: r['expires_at'] as DateTime,
    consumedAt: r['consumed_at'] as DateTime?,
  );
}
