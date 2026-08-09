import 'package:postgres/postgres.dart';

/// Which surface a transaction is serving.
///
/// The API logs in as `bel_api`, which is NOINHERIT and therefore holds no
/// privileges at all. Every transaction begins by declaring one of these with
/// `SET LOCAL ROLE`, and LOCAL means the declaration dies at COMMIT — a pooled
/// connection can never carry an elevated role back into the pool and into
/// somebody else's request (migration 0005).
///
/// The role name is an SQL *identifier*, which cannot be parameterised. It
/// comes from this enum and from nowhere else, so there is no path from a
/// request to that part of the statement.
enum DbSurface {
  /// The traveller. Cannot mark a seat sold, cannot see another traveller's
  /// hold, and has no grant at all on staff, KYB, payouts or the ledger.
  public('bel_public'),

  /// An operator acting on its own tenant.
  tenant('bel_app'),

  /// Our own back office, reading across tenants. Every such read is audited.
  platform('bel_admin'),

  /// Answers one question — "who is this?" — and holds the privileges to
  /// answer it and nothing else (migration 0007).
  ///
  /// It exists because of an ordering problem the other three cannot solve:
  /// turning a bearer token into a user id is a read of `user_accounts` that
  /// happens BEFORE the request has a surface, a tenant or a user. Doing it
  /// as `bel_app` would run the traveller sign-in path with an operator's
  /// authority, which is the trade migration 0005 refused.
  identity('bel_identity');

  const DbSurface(this.roleName);
  final String roleName;
}

/// Who this transaction is for.
///
/// Deliberately dumb: it carries the identifiers and nothing else. Deciding
/// *whether* a caller may act is the job of the middleware that builds one of
/// these, and putting that decision here would put it below the layer that
/// knows the request.
final class DbScope {
  const DbScope._(this.surface, {this.tenantId, this.userId});

  /// A signed-in traveller.
  const DbScope.traveller(String userId)
    : this._(DbSurface.public, userId: userId);

  /// Resolving or creating an account. Carries no user id on purpose: this is
  /// the scope used *while* working out whose request this is, and one that
  /// claimed to already know would be lying.
  const DbScope.identity() : this._(DbSurface.identity);

  /// Browsing without an account. Sees public catalogue rows and nothing that
  /// belongs to anybody.
  const DbScope.anonymous() : this._(DbSurface.public);

  /// An operator's own data.
  const DbScope.tenant(String operatorId)
    : this._(DbSurface.tenant, tenantId: operatorId);

  /// Cross-tenant. Reached only through [PlatformScope], which requires a
  /// stated reason.
  const DbScope.platform(String actorUserId)
    : this._(DbSurface.platform, userId: actorUserId);

  final DbSurface surface;
  final String? tenantId;
  final String? userId;

  Map<String, String> get sessionVariables => {
    // Empty rather than absent. `app_tenant_id()` turns '' into NULL, and NULL
    // matches no tenant row — so a code path that forgets to scope sees
    // nothing instead of everything.
    'app.tenant_id': tenantId ?? '',
    'app.user_id': userId ?? '',
    'app.public': surface == DbSurface.public ? 'on' : 'off',
    'app.platform': surface == DbSurface.platform ? 'on' : 'off',
    'app.identity': surface == DbSurface.identity ? 'on' : 'off',
  };
}

/// The connection pool, and the one place a scope becomes session state.
///
/// Every query in the system goes through [transaction]. There is no method
/// that runs SQL without a scope, which is what makes "did we remember to
/// scope this?" a question the type system answers rather than a review
/// comment.
final class Database {
  Database(this._pool);

  final Pool _pool;

  /// Opens a pool from a `postgres://` URL.
  ///
  /// The pool is small on purpose. Postgres does not get faster with more
  /// connections — past the point where they fit in memory it gets sharply
  /// slower, and our hot path holds row locks. Ten busy connections that
  /// finish are worth more than a hundred that queue.
  factory Database.open(
    String url, {
    int maxConnections = 10,
    Duration queryTimeout = const Duration(seconds: 10),
  }) {
    final parsed = Uri.parse(url);
    final userInfo = parsed.userInfo.split(':');

    return Database(
      Pool.withEndpoints(
        [
          Endpoint(
            host: parsed.host,
            port: parsed.port == 0 ? 5432 : parsed.port,
            database: parsed.pathSegments.isEmpty
                ? 'billetenligne'
                : parsed.pathSegments.first,
            username: userInfo.isNotEmpty ? userInfo[0] : null,
            password: userInfo.length > 1
                ? Uri.decodeComponent(userInfo[1])
                : null,
          ),
        ],
        settings: PoolSettings(
          maxConnectionCount: maxConnections,
          // A held row lock behind a slow query is a seat map that will not
          // load for everyone else on that coach. Fail fast instead.
          queryTimeout: queryTimeout,
          sslMode: parsed.queryParameters['sslmode'] == 'disable'
              ? SslMode.disable
              : SslMode.require,
        ),
      ),
    );
  }

  /// Runs [fn] in a transaction scoped to [scope].
  ///
  /// The role and the session variables are set inside the transaction, so
  /// both are rolled back with it. A handler cannot forget to clean up,
  /// because there is nothing to clean up.
  Future<R> transaction<R>(
    DbScope scope,
    Future<R> Function(TxSession tx) fn, {
    TransactionSettings? settings,
  }) => _pool.runTx((tx) async {
    await _applyScope(tx, scope);
    return fn(tx);
  }, settings: settings);

  Future<void> _applyScope(Session tx, DbScope scope) async {
    await tx.execute('SET LOCAL ROLE ${scope.surface.roleName}');

    final vars = scope.sessionVariables;
    await tx.execute(
      Sql.named('''
        SELECT set_config('app.tenant_id', @tenant,   true),
               set_config('app.user_id',   @user,     true),
               set_config('app.public',    @public,   true),
               set_config('app.platform',  @platform, true),
               set_config('app.identity',  @identity, true)
      '''),
      parameters: {
        'tenant': vars['app.tenant_id'],
        'user': vars['app.user_id'],
        'public': vars['app.public'],
        'platform': vars['app.platform'],
        'identity': vars['app.identity'],
      },
      ignoreRows: true,
    );
  }

  Future<void> close() => _pool.close();
}
