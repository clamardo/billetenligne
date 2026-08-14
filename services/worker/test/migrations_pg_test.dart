@Tags(['integration'])
library;

import 'dart:io';

import 'package:bel_worker/src/migrations.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// The migration runner, against a real Postgres and the real forty-five
/// files.
///
/// There is no unit suite for this and there should not be: every claim it
/// makes is about what a database does — that `CREATE TYPE` twice is an
/// error, that a file's own `BEGIN`/`COMMIT` survives being sent over the
/// simple query protocol, that a half-applied file leaves nothing in the
/// ledger. A fake would agree with whatever this file believed.
///
/// It runs against **its own database**, created and dropped here. Applying
/// forty-five migrations to the database the rest of the suite is using would
/// be a different kind of test.
void main() {
  final seedUrl = Platform.environment['SEED_DATABASE_URL'];
  if (seedUrl == null || seedUrl.isEmpty) {
    test('migration runner', () {}, skip: 'run via tool/integration.sh');
    return;
  }

  final uri = Uri.parse(seedUrl);
  final auth = uri.userInfo.split(':');
  const scratch = 'bel_migrations_test';

  Future<Connection> connect(String database) => Connection.open(
    Endpoint(
      host: uri.host,
      port: uri.port,
      database: database,
      username: auth.first,
      password: auth.length > 1 ? auth[1] : null,
    ),
    settings: const ConnectionSettings(sslMode: SslMode.disable),
  );

  final directory = Directory(
    Platform.environment['MIGRATIONS_DIR'] ?? '../../infra/migrations',
  );

  late Connection admin;
  late Connection target;
  final said = <String>[];

  setUp(() async {
    admin = await connect(uri.pathSegments.first);
    await admin.execute('DROP DATABASE IF EXISTS $scratch WITH (FORCE)');
    await admin.execute('CREATE DATABASE $scratch');
    target = await connect(scratch);
    said.clear();
  });

  tearDown(() async {
    await target.close();
    await admin.execute('DROP DATABASE IF EXISTS $scratch WITH (FORCE)');
    await admin.close();
  });

  Future<MigrationOutcome> run({String? baseline}) => applyMigrations(
    session: target,
    directory: directory,
    baseline: baseline,
    log: said.add,
  );

  test('the files this repository ships all apply, in order', () async {
    final files = migrationFiles(directory);
    expect(files, isNotEmpty, reason: 'no migrations found in $directory');

    final outcome = await run();
    expect(outcome.applied, files.length);
    expect(outcome.isRefusal, isFalse);

    // Not "it did not throw" — the schema is actually there.
    final tables = await target.execute(
      "SELECT count(*) FROM information_schema.tables "
      "WHERE table_schema = 'public'",
    );
    expect(
      tables.first[0],
      isA<int>().having((n) => n, 'tables', greaterThan(20)),
    );
  });

  test('running it twice applies nothing the second time', () async {
    await run();
    final again = await run();
    expect(again.applied, 0);
  });

  test('a file added later is the only one that runs', () async {
    await run();
    await target.execute(
      "DELETE FROM schema_migrations WHERE filename = "
      "(SELECT max(filename) FROM schema_migrations)",
    );
    // The forward-only rule bites here on purpose: the last migration has to
    // survive being applied to a database that already has everything before
    // it, which is the only situation it will ever be applied in.
    final outcome = await run();
    expect(outcome.applied, 1);
  });

  group('a database with a schema and no ledger', () {
    setUp(() async {
      await run();
      await target.execute('DROP TABLE schema_migrations');
      // What the *test* does is not what the test is about.
      said.clear();
    });

    test('is refused rather than guessed at', () async {
      final outcome = await run();
      expect(outcome.refusal, MigrationRefusal.unknownBaseline);
    });

    test('and the refusal writes nothing at all', () async {
      // The bug this is here for: creating the ledger before deciding made
      // the *second* attempt look like a fresh database, and it would then
      // try to apply 0001 over a live schema.
      await run();
      final ledger = await target.execute(
        "SELECT to_regclass('public.schema_migrations') IS NULL",
      );
      expect(ledger.first[0], isTrue);

      final second = await run();
      expect(second.refusal, MigrationRefusal.unknownBaseline);
    });

    test('a baseline says where it is, and nothing re-runs', () async {
      final files = migrationFiles(directory);
      final outcome = await run(baseline: versionOf(files.last));
      expect(outcome.baselined, files.length);
      expect(outcome.applied, 0);
      expect(said.first, contains('baseline'));
    });
  });

  test('the ledger records a file only after it succeeds', () async {
    // Its own two-file directory rather than the real one: a test that writes
    // a deliberately broken migration into `infra/migrations` and then fails
    // half way leaves it there for whoever runs next.
    final scratchDir = Directory.systemTemp.createTempSync('bel_migrations');
    addTearDown(() => scratchDir.deleteSync(recursive: true));
    File('${scratchDir.path}/0001_fine.sql')
      ..createSync()
      ..writeAsStringSync('BEGIN;\nCREATE TABLE fine (id INT);\nCOMMIT;\n');
    File('${scratchDir.path}/0002_broken.sql')
      ..createSync()
      ..writeAsStringSync('BEGIN;\nSELECT 1 FROM no_such_table;\nCOMMIT;\n');

    await expectLater(
      applyMigrations(session: target, directory: scratchDir, log: said.add),
      throwsA(isA<ServerException>()),
    );

    final ledger = await target.execute(
      'SELECT filename FROM schema_migrations',
    );
    expect(ledger.map((r) => r[0]), ['0001_fine.sql']);
  });
}
