import 'dart:io';

import 'package:bel_api/src/infrastructure/config/env.dart';
import 'package:bel_worker/src/migrations.dart';
import 'package:postgres/postgres.dart';

/// Applies every migration this database has not seen yet, in order.
///
///   dart run bin/migrate.dart
///
/// **Why this is a program and not a shell script.** `tool/migrate.sh` has
/// applied migrations to the local stack since the schema existed, and it did
/// it with `docker compose exec psql` — the right tool for a laptop and no
/// tool at all for a cluster, where there is no compose file, no `psql`, and
/// the database is reachable only over the network. A deployment needs a
/// migration step, and the alternative to this file is a second
/// implementation of the ledger written in Kubernetes YAML and quietly
/// disagreeing about which files count as applied. So this is the
/// implementation, and the shell script calls it.
///
/// **It connects as an owner, not as the application.** `bel_api` is
/// NOINHERIT and holds no privileges at all; a role that could both serve
/// requests and rewrite the schema would make row-level security a comment
/// (ADR-0011). `MIGRATE_DATABASE_URL` is a different secret from
/// `DATABASE_URL` in every deployment, and is meant to be.
///
/// The rules — forward-only, recorded after success, a ledger-less schema
/// refused rather than guessed at — live in `bel_worker/src/migrations.dart`,
/// where the integration suite can execute them against a real Postgres.
/// This file is the environment: read it, connect, print, choose an exit
/// code.
Future<void> main() async {
  // The same resolution the API and the worker use: empty is unset, and a
  // secret mounted at BEL__SECRETSDIR is read from its file. The owner
  // connection is the one credential in this system that can rewrite the
  // schema, so it is the last one that should be sitting in an environment
  // every child process inherits.
  final env = Env.resolve(Platform.environment);
  final url = env['MIGRATE_DATABASE_URL'] ?? '';
  if (url.isEmpty) {
    stderr.writeln(
      'MIGRATE_DATABASE_URL is not set. It is the *owner* connection — not '
      'DATABASE_URL, which the API uses and which is deliberately not '
      'allowed to create schema.',
    );
    exit(64);
  }

  final directory = _migrationsDirectory();
  if (directory == null) {
    stderr.writeln(
      'no migrations directory. Set MIGRATIONS_DIR, or run this from a tree '
      'that has infra/migrations in it.',
    );
    exit(66);
  }
  if (migrationFiles(directory).isEmpty) {
    stderr.writeln('no migrations found in ${directory.path}');
    exit(66);
  }

  final connection = await _connect(url);
  final MigrationOutcome outcome;
  try {
    outcome = await applyMigrations(
      session: connection,
      directory: directory,
      baseline: env['MIGRATE_BASELINE'],
    );
  } on ServerException catch (error) {
    // Named rather than swallowed: the file that failed has already been
    // printed, and this is the line somebody pastes into a search.
    stderr.writeln('migration failed: $error');
    await connection.close();
    exit(70);
  } finally {
    if (connection.isOpen) await connection.close();
  }

  if (outcome.refusal == MigrationRefusal.unknownBaseline) {
    stderr.writeln(
      'This database has a schema but no migration ledger, so which files it '
      'has already seen is not knowable from here. Set MIGRATE_BASELINE=0041 '
      'to say everything up to 0041 has been applied.',
    );
    exit(65);
  }

  stdout.writeln(
    outcome.applied == 0
        ? 'schema up to date, nothing to apply'
        : 'schema up to date, ${outcome.applied} applied',
  );
}

Future<Connection> _connect(String url) {
  final parsed = Uri.parse(url);
  final userInfo = parsed.userInfo.split(':');
  return Connection.open(
    Endpoint(
      host: parsed.host,
      port: parsed.port == 0 ? 5432 : parsed.port,
      database: parsed.pathSegments.isEmpty
          ? 'billetenligne'
          : parsed.pathSegments.first,
      username: userInfo.isNotEmpty ? userInfo[0] : null,
      password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
    ),
    settings: ConnectionSettings(
      sslMode: parsed.queryParameters['sslmode'] == 'disable'
          ? SslMode.disable
          : SslMode.require,
      // A migration is not a request. `ALTER TABLE` on a large table takes as
      // long as it takes, and the API pool's ten-second timeout would abort
      // one half way and leave the ledger honest and the schema behind.
      queryTimeout: const Duration(minutes: 30),
      connectTimeout: const Duration(seconds: 30),
    ),
  );
}

/// `MIGRATIONS_DIR`, or `infra/migrations` found by walking up — the same walk
/// the translation catalog and the market file use, for the same reason: the
/// working directory is the package under `dart run` and `/app` in a
/// container.
Directory? _migrationsDirectory() {
  final named = Platform.environment['MIGRATIONS_DIR'] ?? '';
  if (named.isNotEmpty) {
    final directory = Directory(named);
    return directory.existsSync() ? directory : null;
  }

  var dir = Directory.current;
  for (var up = 0; up < 5; up++) {
    final candidate = Directory('${dir.path}/infra/migrations');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
